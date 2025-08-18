# Java Artifact Collector for Azure DevOps Pipelines

This bash script intelligently analyzes Azure DevOps artifact storage folders and collects Java compiled applications while handling 3rd party libraries and excluding test artifacts.

## Features

- **Smart Artifact Detection**: Automatically identifies compiled Java applications (.jar, .war, .ear)
- **3rd Party Library Handling**: Intelligently determines if 3rd party libraries are already included in compiled artifacts
- **Test Artifact Filtering**: Automatically excludes unit test artifacts
- **Archive Validation**: Validates that files are proper Java archives before processing
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
   chmod +x collect_java_artifacts.sh
   ```

## Usage

### Basic Usage

```bash
./collect_java_artifacts.sh /path/to/artifacts
```

### Advanced Usage

```bash
# Enable debug output
./collect_java_artifacts.sh -d /path/to/artifacts

# Enable verbose output
./collect_java_artifacts.sh -v /path/to/artifacts

# Specify custom output directory
./collect_java_artifacts.sh -o /custom/output /path/to/artifacts

# Combine options
./collect_java_artifacts.sh -d -v -o /custom/output /path/to/artifacts
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

### 2. Archive Validation
Each found file is validated to ensure it's a proper Java archive:
- File existence and readability checks
- File size validation (skips empty files)
- Archive structure validation using `unzip -t`

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
1. **Priority 1**: Collect compiled applications (.jar, .war, .ear)
2. **Graceful Exit**: If no compiled apps found, finish gracefully without collecting 3rd party libraries
3. **Always Skip**: Test artifacts and invalid archives

### 6. Output Generation
- Copies selected artifacts to the output directory
- Creates a detailed collection summary (`collection_summary.txt`)
- Provides comprehensive logging throughout the process

## Examples

### Example 1: Basic Collection
```bash
./collect_java_artifacts.sh /tmp/azure-artifacts
```
This will analyze `/tmp/azure-artifacts` and collect artifacts to `./collected_artifacts/`.

### Example 2: Debug Mode with Custom Output
```bash
./collect_java_artifacts.sh -d -o /tmp/collected /tmp/azure-artifacts
```
This enables debug output and saves collected artifacts to `/tmp/collected/`.

### Example 3: Environment Variable Usage
```bash
DEBUG=true VERBOSE=true ./collect_java_artifacts.sh /tmp/azure-artifacts
```
This enables both debug and verbose modes via environment variables.

## Output Structure

```
collected_artifacts/
├── application.jar          # Compiled application
├── webapp.war              # Web application
├── enterprise.ear          # Enterprise application
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

### Azure DevOps Pipeline Integration
```yaml
- task: Bash@3
  inputs:
    targetType: 'inline'
    script: |
      ./collect_java_artifacts.sh -d -v $(Build.ArtifactStagingDirectory)
```

### CI/CD Scripts
```bash
#!/bin/bash
# Collect Java artifacts after build
./collect_java_artifacts.sh -d -o "$WORKSPACE/artifacts" "$BUILD_DIR/target"
```

### Manual Artifact Analysis
```bash
# Analyze a specific build output
./collect_java_artifacts.sh -v /path/to/build/output
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