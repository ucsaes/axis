#!/bin/bash
cd "$(dirname "$0")"
source ./script/setup.sh

./build-debug.sh -Xswiftc -warnings-as-errors
./swift-test.sh

./.debug/axis -h > /dev/null
./.debug/axis --help > /dev/null
./.debug/axis -v | grep -q "0.0.0-SNAPSHOT SNAPSHOT"
./.debug/axis --version | grep -q "0.0.0-SNAPSHOT SNAPSHOT"

./lint.sh
./generate.sh
./script/check-uncommitted-files.sh

echo
echo "✅ All tests have passed successfully"
