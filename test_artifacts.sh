#!/bin/bash

# Test script to create sample Java artifacts for testing the collector
# This script creates various types of Java archives to test the artifact collector

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Create test directory
TEST_DIR="./test_artifacts"
log_info "Creating test artifacts in: $TEST_DIR"

# Clean up existing test directory
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

# Create a simple Java class file for testing
log_info "Creating sample Java class file..."
mkdir -p "$TEST_DIR/classes/com/example/app"
cat > "$TEST_DIR/classes/com/example/app/Main.class" << 'EOF'
// This is a dummy .class file content
// In reality, this would be compiled Java bytecode
public class Main {
    public static void main(String[] args) {
        System.out.println("Hello, World!");
    }
}
EOF

# Create a test class file
mkdir -p "$TEST_DIR/classes/com/example/test"
cat > "$TEST_DIR/classes/com/example/test/TestMain.class" << 'EOF'
// This is a dummy test class file
public class TestMain {
    public void testMethod() {
        // Test method
    }
}
EOF

# Create META-INF structure
mkdir -p "$TEST_DIR/META-INF"
cat > "$TEST_DIR/META-INF/MANIFEST.MF" << 'EOF'
Manifest-Version: 1.0
Main-Class: com.example.app.Main
Created-By: Test Script
EOF

# Create Maven dependency info
mkdir -p "$TEST_DIR/META-INF/maven/com/example/app"
cat > "$TEST_DIR/META-INF/maven/com/example/app/pom.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<project>
    <groupId>com.example</groupId>
    <artifactId>app</artifactId>
    <version>1.0.0</version>
</project>
EOF

# Create services directory
mkdir -p "$TEST_DIR/META-INF/services"
cat > "$TEST_DIR/META-INF/services/com.example.Service" << 'EOF'
com.example.app.ServiceImpl
EOF

# Create different types of archives
log_info "Creating sample Java archives..."

# 1. Main application JAR (contains 3rd party libs)
cd "$TEST_DIR"
zip -r "main-application.jar" classes/ META-INF/ >/dev/null 2>&1
log_success "Created: main-application.jar"

# 2. Web application WAR
mkdir -p WEB-INF/classes
cp -r classes/* WEB-INF/classes/
zip -r "web-application.war" WEB-INF/ META-INF/ >/dev/null 2>&1
log_success "Created: web-application.war"

# 3. Enterprise application EAR
mkdir -p META-INF/application
cat > META-INF/application.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<application>
    <display-name>Test Enterprise Application</display-name>
</application>
EOF
zip -r "enterprise-application.ear" META-INF/ >/dev/null 2>&1
log_success "Created: enterprise-application.ear"

# 4. Test JAR (should be excluded)
cd classes
zip -r "../test-application.jar" com/example/test/ >/dev/null 2>&1
log_success "Created: test-application.jar"

# 5. 3rd party library JAR (standalone)
cd ..
mkdir -p third-party
cat > third-party/ThirdPartyLib.class << 'EOF'
// Dummy 3rd party library class
public class ThirdPartyLib {
    public void doSomething() {
        // 3rd party functionality
    }
}
EOF
cd third-party
zip -r "../spring-core-5.3.0.jar" *.class >/dev/null 2>&1
log_success "Created: spring-core-5.3.0.jar"

# 6. Another 3rd party library
cat > AnotherLib.class << 'EOF'
// Another 3rd party library
public class AnotherLib {
    public void process() {
        // Processing logic
    }
}
EOF
zip -r "../logback-core-1.2.0.jar" *.class >/dev/null 2>&1
log_success "Created: logback-core-1.2.0.jar"

# 7. Empty/invalid JAR
cd ..
echo "" > "invalid-archive.jar"
log_warning "Created: invalid-archive.jar (corrupted)"

# 8. Test JAR with test in filename
zip -r "integration-test.jar" classes/com/example/test/ >/dev/null 2>&1
log_success "Created: integration-test.jar"

# Clean up temporary files
rm -rf classes/ META-INF/ WEB-INF/ third-party/

cd ..

log_success "Test artifacts created successfully!"
log_info "Test artifacts directory: $TEST_DIR"
log_info ""
log_info "Files created:"
ls -la "$TEST_DIR"
log_info ""
log_info "You can now test the collector script with:"
log_info "./collect_java_artifacts.sh -d -v $TEST_DIR"
log_info ""
log_info "Expected behavior:"
log_info "- main-application.jar, web-application.war, enterprise-application.ear should be collected"
log_info "- test-application.jar, integration-test.jar should be excluded (test artifacts)"
log_info "- spring-core-5.3.0.jar, logback-core-1.2.0.jar should be identified as 3rd party libs (but not collected)"
log_info "- invalid-archive.jar should be marked as invalid" 