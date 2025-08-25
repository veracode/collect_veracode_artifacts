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

OPTIONS:
    -d, --debug          Enable debug output
    -v, --verbose        Enable verbose output
    -h, --help           Show this help message
    -o, --output         Specify output folder (default: ./collected_artifacts)
    --no-rename          Skip renaming package manager files
    --no-cli             Skip Veracode CLI download and integration

ARGUMENTS:
    artifact_folder       Path to the Azure DevOps artifact folder to analyze
    output_folder         Optional: Path where to collect the artifacts

EXAMPLES:
    $SCRIPT_NAME -d /path/to/artifacts
    $SCRIPT_NAME -v -o /custom/output /path/to/artifacts
    $SCRIPT_NAME --debug --verbose /path/to/artifacts
    $SCRIPT_NAME --no-rename --no-cli /path/to/artifacts

ENVIRONMENT VARIABLES:
    DEBUG=true           Enable debug mode
    VERBOSE=true         Enable verbose mode

SUPPORTED LANGUAGES:
    Java: .jar, .war, .ear files
    .NET: .dll files (with .pdb files when available)

ENHANCED FEATURES:
    - Automatically renames package manager files (*_backup suffix)
    - Downloads and integrates Veracode CLI for artifact validation
    - Supports multiple build systems (Maven, Gradle, .NET, C/C++, etc.)

PACKAGE MANAGER FILES RENAMED:
    Java: pom.xml, build.xml, *.gradle, gradle-wrapper.*, maven-wrapper.*
    .NET: *.csproj, *.vcxproj, *.sln, *.nuspec, *.props, *.targets
    C/C++: Makefile, CMakeLists.txt, *.cmake, *.vcxproj
    Other: package.json, requirements.txt, go.mod, Gemfile, composer.json
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
        # For .NET DLLs, be more careful about test detection
        if [[ "$file_type" == "dll" ]]; then
            # Only flag as test if it's clearly a test DLL (e.g., ends with .test.dll or contains specific test patterns)
            if [[ "$filename" =~ \.test\.dll$ ]] || \
               [[ "$filename" =~ ^test.*\.dll$ ]] || \
               [[ "$filename" =~ ^.*test.*\.dll$ ]] && [[ "$filename" =~ -test- ]]; then
                log_debug "File appears to be a test artifact based on filename: $filename"
                return 0
            else
                log_debug "File has 'test' in name but appears to be an application DLL: $filename"
                return 1
            fi
        else
            log_debug "File appears to be a test artifact based on filename: $filename"
            return 0
        fi
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
    local compiled_count=${#compiled_apps[@]}
    local third_party_count=${#third_party_libs[@]}
    local test_count=${#test_artifacts[@]}
    local invalid_count=${#invalid_archives[@]}
    
    # Ensure counts are at least 0
    compiled_count=${compiled_count:-0}
    third_party_count=${third_party_count:-0}
    test_count=${test_count:-0}
    invalid_count=${invalid_count:-0}
    
    log_info "Compiled applications: $compiled_count"
    log_info "3rd party libraries: $third_party_count"
    log_info "Test artifacts (skipped): $test_count"
    log_info "Invalid archives: $invalid_count"
    
    # Store results for collection (safely)
    if [[ ${#compiled_apps[@]} -gt 0 ]]; then
        # Use a more compatible array expansion method
        for archive in "${compiled_apps[@]}"; do
            COMPILED_APPS+=("$archive")
        done
    fi
    
    if [[ ${#third_party_libs[@]} -gt 0 ]]; then
        # Use a more compatible array expansion method
        for lib in "${third_party_libs[@]}"; do
            THIRD_PARTY_LIBS+=("$lib")
        done
    fi
    
    if [[ ${#test_artifacts[@]} -gt 0 ]]; then
        # Use a more compatible array expansion method
        for test in "${test_artifacts[@]}"; do
            TEST_ARTIFACTS+=("$test")
        done
    fi
    
    if [[ ${#invalid_archives[@]} -gt 0 ]]; then
        # Use a more compatible array expansion method
        for invalid in "${invalid_archives[@]}"; do
            INVALID_ARCHIVES+=("$invalid")
        done
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
        
        # For .NET, collect ALL DLLs (both 1st party and 3rd party)
        log_info "Adding .NET DLL for collection: $relative_path"
        compiled_apps+=("$dll")
        
        # Look for corresponding PDB file for ALL DLLs
        find_pdb_files "$dll"
    done
    
    # Summary
    log_info "=== .NET Analysis Summary ==="
    log_info "Total .NET DLLs found: ${#dll_files[@]}"
    
    # Count arrays safely
    local compiled_count=${#compiled_apps[@]}
    local test_count=${#test_artifacts[@]}
    local pdb_count=${#DOTNET_PDBS[@]}
    local missing_pdb_count=${#MISSING_PDBS[@]}
    
    # Ensure counts are at least 0
    compiled_count=${compiled_count:-0}
    test_count=${test_count:-0}
    pdb_count=${pdb_count:-0}
    missing_pdb_count=${missing_pdb_count:-0}
    
    log_info "DLLs to be collected: $compiled_count"
    log_info "Test artifacts (skipped): $test_count"
    log_info "PDB files found: $pdb_count"
    log_info "Missing PDB files: $missing_pdb_count"
    
    # Store results for collection (safely)
    if [[ ${#compiled_apps[@]} -gt 0 ]]; then
        # Use a more compatible array expansion method
        for dll in "${compiled_apps[@]}"; do
            DOTNET_DLLS+=("$dll")
        done
    fi
    
    # Add .NET DLLs to the main compiled apps array
    if [[ ${#compiled_apps[@]} -gt 0 ]]; then
        log_debug "Adding ${#compiled_apps[@]} .NET DLLs to COMPILED_APPS array"
        # Use a more compatible array expansion method
        for dll in "${compiled_apps[@]}"; do
            COMPILED_APPS+=("$dll")
        done
        # Update the count (ensure it's initialized)
        COMPILED_COUNT=${COMPILED_COUNT:-0}
        COMPILED_COUNT=$((COMPILED_COUNT + compiled_count))
        log_debug "COMPILED_APPS array now contains ${#COMPILED_APPS[@]} items"
    else
        log_debug "No .NET DLLs to add to COMPILED_APPS array"
    fi
    
    # Add .NET test artifacts to the main array
    if [[ ${#test_artifacts[@]} -gt 0 ]]; then
        # Use a more compatible array expansion method
        for test in "${test_artifacts[@]}"; do
            TEST_ARTIFACTS+=("$test")
        done
        # Update the count (ensure it's initialized)
        TEST_COUNT=${TEST_COUNT:-0}
        TEST_COUNT=$((TEST_COUNT + test_count))
    fi
    
    # Store .NET specific counts
    DOTNET_COMPILED_COUNT=$compiled_count
    DOTNET_TEST_COUNT=$test_count
    DOTNET_PDB_COUNT=$pdb_count
    DOTNET_MISSING_PDB_COUNT=$missing_pdb_count
}

# Function to rename package manager files
rename_package_manager_files() {
    local input_folder="$1"
    
    log_info "Renaming package manager files to prevent conflicts..."
    
    local renamed_count=0
    local skipped_count=0
    
    # Define package manager files to copy and rename
    local package_files=(
        "Makefile"
        "makefile"
        "pom.xml"
        "build.xml"
        "build.gradle"
        "gradle.properties"
        "gradle-wrapper.properties"
        "gradle-wrapper.jar"
        "maven-wrapper.properties"
        "maven-wrapper.jar"
        "CMakeLists.txt"
    )

    
        #"package.json"
        #"package-lock.json"
        #"yarn.lock"
        #"requirements.txt"
        #"setup.py"
        #"Pipfile"
        #"Pipfile.lock"
        #"poetry.lock"
        #"pyproject.toml"
        #"Cargo.toml"
        #"Cargo.lock"
        #"go.mod"
        #"go.sum"
        #"Gemfile"
        #"Gemfile.lock"
        #"composer.json"
        #"composer.lock"
        #"pubspec.yaml"
        #"pubspec.lock"
    
    
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
    
    # Copy wildcard pattern files
    local wildcard_patterns=(
        "*.csproj"
        "*.vcxproj"
        "*.vcxproj.filters"
        "*.vcxproj.user"
        "*.cmake"
        "*.gradle"
        "*.sln"
        "*.vcproj"
        "*.dproj"
        "*.bpr"
        "*.cbp"
        "*.workspace"
        "*.project"
        "*.classpath"
        "*.nuspec"
        "*.props"
        "*.targets"
        "*.config"
    )
        #"*.conf"
        #"*.ini"
        #"*.cfg"
        #"*.yml"
        #"*.yaml"
        #"*.toml"
        #"*.lock"
    
    for pattern in "${wildcard_patterns[@]}"; do
        while IFS= read -r -d '' file; do
            local basename=$(basename "$file")
            local backup_name="${basename}_backup"
            local backup_path="$input_folder/$backup_name"
            
            # Skip if already renamed
            if [[ "$basename" == *"_backup" ]]; then
                continue
            fi
            
            # Check if backup already exists
            if [[ -f "$backup_path" ]]; then
                log_warning "Backup already exists for: $basename"
                skipped_count=$((skipped_count + 1))
                continue
            fi
            
            # Rename the file
            if mv "$file" "$backup_path" 2>/dev/null; then
                log_success "Renamed: $basename → $backup_name"
                renamed_count=$((renamed_count + 1))
            else
                log_error "Failed to rename: $basename"
            fi
        done < <(find "$input_folder" -name "$pattern" -type f -print0 2>/dev/null)
    done
    
    # Store the count in a global variable for the main script to access
    RENAMED_COUNT=$renamed_count
    SKIPPED_COUNT=$skipped_count
    
    log_info "Package manager file renaming complete: $renamed_count renamed, $skipped_count skipped"
    return 0 # Always return success (0) to prevent set -e from exiting
}

# Function to download and install Veracode CLI
download_veracode_cli() {
    local output_folder="$1"
    local input_folder="$2"
    
    log_info "Downloading Veracode CLI..."
    cd "$input_folder"

    # Use the simpler curl | sh method as requested
    if curl -fsS https://tools.veracode.com/veracode-cli/install | sh; then
        log_success "Veracode CLI downloaded and installed successfully"
        return 0
    else
        log_error "Failed to download and install Veracode CLI"
        return 1
    fi
}

# Function to run Veracode CLI
run_veracode_cli() {
    local output_folder="$1"
    local input_folder="$2"
    
    log_info "Running Veracode CLI to create missing artifacts..."
    
    # Execute veracode package command on the input folder
    if "$input_folder"/veracode package -a -s "$input_folder" -o "$output_folder"; then
        log_success "Veracode CLI package command executed successfully"
        log_info "Package created in: $output_folder"
        return 0
    else
        log_warning "Veracode CLI package command failed (this may be normal for local testing)"
        log_info "The CLI command was executed but may need proper setup for full functionality"
        log_info "For production use, please refer to Veracode CLI documentation"
        return 0  # Don't fail the script for CLI issues
    fi
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
        log_debug "COMPILED_APPS array contents:"
        for i in "${!COMPILED_APPS[@]}"; do
            log_debug "  [$i]: ${COMPILED_APPS[$i]}"
        done
        
        # Track unique filenames to avoid duplicates
        local duplicate_count=0
        local unique_files=()
        
        for app in "${COMPILED_APPS[@]}"; do
            local filename=$(basename "$app")
            local dest_path="$output_folder/$filename"
            
            log_debug "Processing file: $app -> $filename"
            
            # Check if source file still exists and is readable
            if [[ ! -f "$app" ]]; then
                log_error "Source file no longer exists: $app"
                continue
            fi
            
            if [[ ! -r "$app" ]]; then
                log_error "Source file not readable: $app"
                continue
            fi
            
            # Check if we already have this filename in the output directory
            if [[ -f "$dest_path" ]]; then
                log_info "Skipping duplicate: $filename (already collected)"
                duplicate_count=$((duplicate_count + 1))
                continue
            fi
            
            log_debug "Attempting to copy: $app to $dest_path"
            
            # Try to copy with more detailed error reporting
            local copy_result
            if cp "$app" "$dest_path" 2>&1; then
                copy_result=0
            else
                copy_result=$?
            fi
            
            if [[ $copy_result -eq 0 ]]; then
                log_success "Collected: $filename"
                unique_files+=("$filename")
                collected_count=$((collected_count + 1))
                log_debug "Copy successful, collected_count now: $collected_count"
            else
                log_error "Failed to collect: $filename (exit code: $copy_result)"
                log_debug "Copy failed for: $app"
                
                # Try to get more information about the failure
                if [[ ! -f "$app" ]]; then
                    log_error "Source file disappeared during copy: $app"
                elif [[ ! -r "$app" ]]; then
                    log_error "Source file became unreadable during copy: $app"
                elif [[ ! -w "$output_folder" ]]; then
                    log_error "Output folder is not writable: $output_folder"
                else
                    log_error "Unknown copy failure for: $app"
                fi
            fi
        done
        
        if [[ $duplicate_count -gt 0 ]]; then
            log_info "Skipped $duplicate_count duplicate files"
        fi
        
        log_debug "Collection loop completed. collected_count: $collected_count, unique_files count: ${#unique_files[@]}"
        
        # Update the count to reflect actual unique files collected
        collected_count=${#unique_files[@]}
        log_debug "Final collected_count after unique_files adjustment: $collected_count"
        
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
            
            # Add enhanced functionality information
            echo ""
            echo "=== Enhanced Functionality ==="
            if [[ "$NO_RENAME" != "true" ]]; then
                echo "Package manager files renamed: Yes (with _backup suffix)"
                echo "Veracode CLI integration: $([[ "$NO_CLI" != "true" ]] && echo "Yes" || echo "No")"
            else
                echo "Package manager files renamed: No (--no-rename option used)"
                echo "Veracode CLI integration: No (requires package manager file renaming)"
            fi
            
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
            fi
            
            # Show 3rd party libraries if any were collected
            if [[ ${#THIRD_PARTY_LIBS[@]} -gt 0 ]]; then
                echo ""
                echo "3rd party libraries:"
                if [[ "$DETECTED_LANGUAGE" == "dotnet" ]] || [[ "$DETECTED_LANGUAGE" == "mixed" ]]; then
                    echo "  - All 3rd party DLLs are collected for .NET applications:"
                    for lib in "${THIRD_PARTY_LIBS[@]}"; do
                        local filename=$(basename "$lib")
                        echo "    * $filename"
                    done
                else
                    for lib in "${THIRD_PARTY_LIBS[@]}"; do
                        local filename=$(basename "$lib")
                        echo "  - $filename"
                    done
                fi
            fi
            
            # Show test artifacts if any were skipped
            if [[ ${#TEST_ARTIFACTS[@]} -gt 0 ]]; then
                echo ""
                echo "Test artifacts skipped:"
                for test in "${TEST_ARTIFACTS[@]}"; do
                    local filename=$(basename "$test")
                    echo "  - $filename"
                done
            fi
            
            # Show invalid archives if any were found
            if [[ ${#INVALID_ARCHIVES[@]} -gt 0 ]]; then
                echo ""
                echo "Invalid archives found:"
                for invalid in "${INVALID_ARCHIVES[@]}"; do
                    local filename=$(basename "$invalid")
                    echo "  - $filename"
                done
            fi
        } > "$summary_file"
        
        log_info "Summary written to: $summary_file"
        
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
                    collected_count=$((collected_count + 1))
                else
                    log_error "Failed to collect PDB: $filename"
                fi
            done
        fi
        
        # Zip .NET artifacts if .NET was detected
        if [[ "$DETECTED_LANGUAGE" == "dotnet" ]] || [[ "$DETECTED_LANGUAGE" == "mixed" ]]; then
            log_debug "Starting .NET artifacts zip process..."
            zip_dotnet_artifacts "$output_folder"
            local zip_result=$?
            log_debug "Zip process returned: $zip_result"
            
            if [[ $zip_result -eq 0 ]]; then
                log_success ".NET artifacts zip process completed successfully"
            else
                log_error ".NET artifacts zip process failed"
            fi
        fi
        
        if [[ $collected_count -gt 0 ]]; then
            log_success "Collection complete! Collected $collected_count files"
        else
            log_warning "No files were collected - no compiled applications found"
        fi
    fi
    
    # If no compiled applications found, finish gracefully
    if [[ ${#COMPILED_APPS[@]} -eq 0 ]]; then
        log_warning "No compiled applications found in the artifact folder."
        log_info "3rd party libraries are not collected when no compiled applications are present."
        log_info "Script will finish gracefully."
    else
        # Check if we have main application files that contain dependencies
        local has_main_app=false
        local has_dotnet_dlls=false
        
        # Check for Java main applications (WAR/EAR)
        for app in "${COMPILED_APPS[@]}"; do
            local app_ext="${app##*.}"
            if [[ "$app_ext" == "war" ]] || [[ "$app_ext" == "ear" ]]; then
                has_main_app=true
                log_info "Main Java application found: $(basename "$app") - this contains Java dependencies"
                break
            fi
        done
        
        # Check for .NET DLLs
        if [[ ${#DOTNET_DLLS[@]} -gt 0 ]]; then
            has_dotnet_dlls=true
            log_info "Found ${#DOTNET_DLLS[@]} .NET DLLs that will be collected separately"
        fi
        
        if [[ "$has_main_app" == "true" ]]; then
            if [[ "$has_dotnet_dlls" == "true" ]]; then
                log_info "Mixed project detected: Java WAR/EAR + .NET DLLs"
                log_info "Java dependencies are included in the main application"
                log_info ".NET DLLs will be collected separately"
            else
                log_info "Java-only project: WAR/EAR contains all dependencies"
                log_info "Only the main application file(s) will be collected"
            fi
        fi
    fi
    
    log_debug "Enhanced functionality section completed, continuing to final success message..."
    log_success "Script completed successfully!"
    if [[ "$DETECTED_LANGUAGE" == "dotnet" ]] || [[ "$DETECTED_LANGUAGE" == "mixed" ]]; then
        if [[ ${#MISSING_PDBS[@]} -gt 0 ]]; then
            log_warning "Note: Some .NET DLLs are missing PDB files, which may affect scan accuracy."
        fi
    fi
}

# Function to zip .NET artifacts
zip_dotnet_artifacts() {
    local output_folder="$1"
    local zip_name="pre-compiled-dotnet-artifacts.zip"
    local zip_path="$output_folder/$zip_name"
    
    log_info "Creating .NET artifacts zip file: $zip_name"
    
    # Check if we have any .NET artifacts to zip
    local dotnet_files=()
    
    # Find all DLL and PDB files in the output folder
    while IFS= read -r -d '' file; do
        local extension="${file##*.}"
        if [[ "$extension" == "dll" ]] || [[ "$extension" == "pdb" ]]; then
            dotnet_files+=("$file")
        fi
    done < <(find "$output_folder" -maxdepth 1 -type f \( -name "*.dll" -o -name "*.pdb" \) -print0 2>/dev/null)
    
    if [[ ${#dotnet_files[@]} -eq 0 ]]; then
        log_warning "No .NET artifacts found to zip"
        return 0
    fi
    
    log_info "Found ${#dotnet_files[@]} .NET artifacts to zip"
    
    # Create the zip file
    if cd "$output_folder" && zip -q "$zip_name" "${dotnet_files[@]##*/}" 2>/dev/null; then
        log_success "Successfully created .NET artifacts zip: $zip_name"
        
        # Remove the individual .NET files, keeping only the zip
        local removed_count=0
        for file in "${dotnet_files[@]}"; do
            local filename=$(basename "$file")
            if rm "$filename" 2>/dev/null; then
                log_debug "Removed individual file: $filename"
                removed_count=$((removed_count + 1))
            else
                log_warning "Failed to remove individual file: $filename"
            fi
        done
        
        log_info "Removed $removed_count individual .NET files, keeping only the zip archive"
        
        # Update the collection summary
        local summary_file="$output_folder/collection_summary.txt"
        if [[ -f "$summary_file" ]]; then
            echo "" >> "$summary_file"
            echo "=== .NET Artifacts Zipped ===" >> "$summary_file"
            echo "Zip file created: $zip_name" >> "$summary_file"
            echo "Individual .NET files removed: $removed_count" >> "$summary_file"
            echo "Zip contains: ${#dotnet_files[@]} .NET artifacts" >> "$summary_file"
        fi
        
        return 0
    else
        log_error "Failed to create .NET artifacts zip file"
        return 1
    fi
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
            --no-rename)
                NO_RENAME=true
                shift
                ;;
            --no-cli)
                NO_CLI=true
                shift
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
    
    if ! command -v curl >/dev/null 2>&1; then
        log_warning "Required dependency 'curl' not found. Veracode CLI download will be skipped."
        NO_CLI=true
    fi
    
    # Initialize new option variables
    NO_RENAME=${NO_RENAME:-false}
    NO_CLI=${NO_CLI:-false}
    
    log_info "Enhanced features:"
    log_info "  Package manager file renaming: $([[ "$NO_RENAME" == "true" ]] && echo "DISABLED" || echo "ENABLED")"
    log_info "  Veracode CLI integration: $([[ "$NO_CLI" == "true" ]] && echo "DISABLED" || echo "ENABLED")"
    log_info ""
    
    # Analyze the artifact folder
    analyze_artifact_folder "$artifact_folder"
    
    # Collect artifacts
    collect_artifacts "$output_folder"
    
    # Rename package manager files to prevent conflicts
    if [[ "$NO_RENAME" != "true" ]]; then
        log_debug "Starting package manager file renaming..."
        rename_package_manager_files "$artifact_folder"
        log_debug "Package manager file renaming returned: $?"
        log_info "Package manager file renaming completed: ${RENAMED_COUNT:-0} files renamed"
    else
        log_info "Package manager file renaming skipped (--no-rename option)"
    fi
    
    # Download and integrate Veracode CLI (independent of package manager renaming)
    if [[ "$NO_CLI" != "true" ]]; then
        log_debug "Starting Veracode CLI download..."
        if download_veracode_cli "$output_folder" "$artifact_folder"; then
            log_debug "Veracode CLI download successful, starting integration..."
            run_veracode_cli "$output_folder" "$artifact_folder"
            log_info "Veracode CLI integration completed"
        else
            log_warning "Veracode CLI download failed - continuing without CLI integration"
        fi
    else
        log_info "Veracode CLI integration skipped (--no-cli option)"
    fi
    
    log_info "Enhanced functionality completed"
    
    log_debug "Enhanced functionality section completed, continuing to final success message..."
    log_success "Script completed successfully!"
    if [[ "$DETECTED_LANGUAGE" == "dotnet" ]] || [[ "$DETECTED_LANGUAGE" == "mixed" ]]; then
        if [[ ${#MISSING_PDBS[@]} -gt 0 ]]; then
            log_warning "Note: Some .NET DLLs are missing PDB files, which may affect scan accuracy."
        fi
    fi
}

# Run main function with all arguments
main "$@" 