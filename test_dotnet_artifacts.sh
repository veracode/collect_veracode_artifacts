#!/bin/bash

# Test script for .NET artifact collection
# This script creates sample .NET artifacts to test the collector

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
TEST_DIR="./test-dotnet-artifacts"

echo "=== Creating Test .NET Artifacts ==="

# Clean up previous test directory
if [[ -d "$TEST_DIR" ]]; then
    rm -rf "$TEST_DIR"
fi

# Create test directory structure
mkdir -p "$TEST_DIR/bin/Debug"
mkdir -p "$TEST_DIR/bin/Release"
mkdir -p "$TEST_DIR/obj/Debug"
mkdir -p "$TEST_DIR/packages"
mkdir -p "$TEST_DIR/TestProject/bin/Debug"
mkdir -p "$TEST_DIR/bin/Debug/lib"

echo "Created directory structure"

# Create sample .NET DLLs (1st party applications)
echo "Creating sample .NET DLLs..."

# Main application DLL
echo "public class Program { }" > "$TEST_DIR/bin/Debug/MyApp.dll"
echo "public class Program { }" > "$TEST_DIR/bin/Release/MyApp.dll"

# Business logic DLLs
echo "public class BusinessLogic { }" > "$TEST_DIR/bin/Debug/BusinessLogic.dll"
echo "public class DataAccess { }" > "$TEST_DIR/bin/Debug/DataAccess.dll"
echo "public class WebAPI { }" > "$TEST_DIR/bin/Debug/WebAPI.dll"

# Create corresponding PDB files for some DLLs
echo "PDB content for MyApp" > "$TEST_DIR/bin/Debug/MyApp.pdb"
echo "PDB content for BusinessLogic" > "$TEST_DIR/bin/Debug/BusinessLogic.pdb"
# Note: DataAccess.dll and WebAPI.dll will be missing PDB files

# Create 3rd party library DLLs
echo "public class SystemComponent { }" > "$TEST_DIR/packages/System.ComponentModel.dll"
echo "public class NewtonsoftJson { }" > "$TEST_DIR/packages/Newtonsoft.Json.dll"
echo "public class Log4Net { }" > "$TEST_DIR/packages/log4net.dll"

# Create test DLLs
echo "public class UnitTest { }" > "$TEST_DIR/TestProject/bin/Debug/TestProject.dll"
echo "public class IntegrationTest { }" > "$TEST_DIR/TestProject/bin/Debug/IntegrationTest.dll"

# Create some files in lib directories (should be treated as 3rd party)
echo "public class ThirdPartyLib { }" > "$TEST_DIR/bin/Debug/lib/ThirdPartyComponent.dll"

echo ""
echo "=== Test .NET Artifacts Created ==="
echo "Test directory: $TEST_DIR"
echo ""
echo "Files created:"
find "$TEST_DIR" -name "*.dll" -o -name "*.pdb" | sort
echo ""
echo "Expected behavior:"
echo "- MyApp.dll, BusinessLogic.dll, DataAccess.dll, WebAPI.dll should be collected (1st party)"
echo "- MyApp.pdb and BusinessLogic.pdb should be collected"
echo "- DataAccess.dll and WebAPI.dll should trigger missing PDB warnings"
echo "- System.ComponentModel.dll, Newtonsoft.Json.dll, log4net.dll should be collected (3rd party)"
echo "- TestProject.dll, IntegrationTest.dll should be skipped (test artifacts)"
echo "- ThirdPartyComponent.dll should be collected (3rd party, in lib directory)"
echo "- All DLLs (1st + 3rd party) are required for proper .NET scanning"
echo ""
echo "Run the collector with:"
echo "./collect_java_artifacts.sh -d -o ./veracode-artifacts \"$TEST_DIR\""
