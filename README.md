# Java and .NET Artifact Collector

This bash script intelligently analyzes artifact storage folders and collects Java and .NET compiled applications while handling 3rd party libraries and excluding test artifacts. It's designed for use in CI/CD pipelines, build systems, and general artifact management scenarios.

## 🚀 Quick Start

Ready-to-use CI/CD pipeline examples are included for:
- **Azure DevOps**: `azure-pipeline-example.yml` - Complete pipeline with artifact collection and Veracode scanning
- **GitHub Actions**: `github-actions-example.yml` - Full workflow using the official Veracode GitHub Action
- **GitLab CI**: `gitlab-ci-example.yml` - Complete GitLab CI pipeline with Veracode integration

## Features

- **Smart Artifact Detection**: Automatically identifies compiled Java applications (.jar, .war, .ear) and .NET applications (.dll, .exe, .nupkg)
- **3rd Party Library Handling**: Intelligently determines if 3rd party libraries are already included in compiled artifacts
- **Test Artifact Filtering**: Automatically excludes unit test artifacts
- **Archive Validation**: Validates that files are proper Java archives or .NET assemblies before processing
- **Comprehensive Logging**: Multiple verbosity levels with colored output for easy debugging
- **Flexible Output**: Configurable output directory with detailed collection summary

## Requirements

- **Bash**: Version 4.0 or higher (for associative arrays and advanced features)
- **unzip**: For archive validation and content analysis
- **stat**: For file size checking (usually available on most systems)

## Installation

1. Download the script to your system
2. Make it executable:
   ```bash
   chmod +x collect_veracode_artifacts.sh
   ```

## Usage

### Basic Usage

```bash
./collect_veracode_artifacts.sh /path/to/artifacts
```

### Advanced Usage

```bash
# Enable debug output
./collect_veracode_artifacts.sh -d /path/to/artifacts

# Enable verbose output
./collect_veracode_artifacts.sh -v /path/to/artifacts

# Specify custom output directory
./collect_veracode_artifacts.sh -o /custom/output /path/to/artifacts

# Combine options
./collect_veracode_artifacts.sh -d -v -o /custom/output /path/to/artifacts
```

### Command Line Options

| Option | Long Option | Description |
|--------|-------------|-------------|
| `-d` | `--debug` | Enable debug output |
| `-v` | `--verbose` | Enable verbose output |
| `-h` | `--help` | Show help message |
| `-o` | `--output` | Specify output folder (default: `./collected_artifacts`) |

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `DEBUG` | Enable debug mode | `false` |
| `VERBOSE` | Enable verbose mode | `false` |

## How It Works

### 1. Folder Analysis
The script starts by scanning the specified artifact folder for:
- `.jar` files (Java Archive)
- `.war` files (Web Application Archive)
- `.ear` files (Enterprise Application Archive)
- `.dll` files (.NET Dynamic Link Library)
- `.exe` files (.NET Executable)
- `.nupkg` files (.NET NuGet Package)

### 2. Archive Validation
Each found file is validated to ensure it's a proper Java archive or .NET assembly:
- File existence and readability checks
- File size validation (skips empty files)
- Archive structure validation using `unzip -t` for Java archives
- Assembly validation for .NET files

### 3. Test Artifact Detection
JAR files are analyzed to identify test artifacts:
- Filename pattern matching (contains "test", "Test", "TEST")
- Content analysis for test-related classes and dependencies
- Manifest file inspection for test indicators

### 4. 3rd Party Library Analysis
JAR files are examined to determine if they contain 3rd party libraries:
- META-INF structure analysis
- Package name pattern matching
- Dependency information detection

### 5. Intelligent Collection
The script follows this collection strategy:
1. **Priority 1**: Collect compiled applications (.jar, .war, .ear, .dll, .exe, .nupkg)
2. **Graceful Exit**: If no compiled apps found, finish gracefully without collecting 3rd party libraries
3. **Always Skip**: Test artifacts and invalid archives

### 6. Output Generation
- Copies selected artifacts to the output directory
- Creates a detailed collection summary (`collection_summary.txt`)
- Provides comprehensive logging throughout the process

## Examples

### Example 1: Basic Collection
```bash
./collect_veracode_artifacts.sh /tmp/build-artifacts
```
This will analyze `/tmp/build-artifacts` and collect artifacts to `./collected_artifacts/`.

### Example 2: Debug Mode with Custom Output
```bash
./collect_veracode_artifacts.sh -d -o /tmp/collected /tmp/build-artifacts
```
This enables debug output and saves collected artifacts to `/tmp/collected/`.

### Example 3: Environment Variable Usage
```bash
DEBUG=true VERBOSE=true ./collect_veracode_artifacts.sh /tmp/build-artifacts
```
This enables both debug and verbose modes via environment variables.

## Output Structure

```
collected_artifacts/
├── application.jar          # Compiled Java application
├── webapp.war              # Java web application
├── enterprise.ear          # Java enterprise application
├── app.dll                 # .NET assembly
├── console.exe             # .NET executable
├── package.nupkg           # .NET NuGet package
└── collection_summary.txt  # Detailed collection report
```

## Collection Summary

The script generates a `collection_summary.txt` file containing:
- Timestamp of collection
- Source folder path
- Count of collected artifacts by type
- List of all collected files
- Count of skipped test artifacts
- Count of invalid archives found

## Debug Output

When debug mode is enabled (`-d` or `DEBUG=true`), the script provides detailed information about:
- File validation steps
- Archive content analysis
- Decision-making process for each file
- Internal state and variable values

## Verbose Output

When verbose mode is enabled (`-v` or `VERBOSE=true`), the script shows:
- All discovered files
- Detailed processing steps
- File analysis results

## Error Handling

The script includes comprehensive error handling:
- Graceful failure for missing dependencies
- Detailed error messages for invalid inputs
- Safe handling of corrupted or invalid archives
- Proper cleanup of temporary files

## Use Cases

### CI/CD Pipeline Integration

This script is designed to work seamlessly with major CI/CD platforms. Complete pipeline examples are provided for each platform:

#### Azure DevOps
```yaml
- task: Bash@3
  inputs:
    targetType: 'inline'
    script: |
      ./collect_veracode_artifacts.sh -d -v $(Build.ArtifactStagingDirectory)
```
**Complete example**: See `azure-pipeline-example.yml` for a full pipeline that collects artifacts and runs Veracode scans.

#### GitHub Actions
```yaml
- name: Collect Artifacts
  run: ./collect_veracode_artifacts.sh -d -v ${{ github.workspace }}/build
```
**Complete example**: See `github-actions-example.yml` for a full workflow that integrates with the Veracode GitHub Action.

#### GitLab CI
```yaml
- script: ./collect_veracode_artifacts.sh -d -v $CI_PROJECT_DIR/build
```
**Complete example**: See `gitlab-ci-example.yml` for a complete GitLab CI pipeline with artifact collection and Veracode integration.

### Build System Integration
```bash
#!/bin/bash
# Collect artifacts after Maven build
./collect_veracode_artifacts.sh -d -o "$WORKSPACE/artifacts" "$BUILD_DIR/target"

# Collect artifacts after .NET build
./collect_veracode_artifacts.sh -d -o "$WORKSPACE/artifacts" "$BUILD_DIR/bin"
```

### Manual Artifact Analysis
```bash
# Analyze a specific build output
./collect_veracode_artifacts.sh -v /path/to/build/output

# Analyze deployment artifacts
./collect_veracode_artifacts.sh -v /path/to/deployment/folder
```

## Troubleshooting

### Common Issues

1. **Permission Denied**: Ensure the script is executable (`chmod +x`)
2. **unzip not found**: Install unzip package for your system
3. **Empty output**: Check if the artifact folder contains valid Java archives
4. **Test artifacts collected**: Verify the test detection logic meets your needs

### Debug Tips

- Use `-d` flag to see detailed decision-making process
- Use `-v` flag to see all discovered files
- Check the collection summary for detailed results
- Verify file permissions and accessibility

## Contributing

Feel free to submit issues, feature requests, or pull requests to improve the script.

## License

This script is provided as-is for educational and operational purposes. 