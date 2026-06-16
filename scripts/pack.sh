#!/bin/bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

rm -rf $SCRIPT_DIR/../package/src/main/ets
rm -rf $SCRIPT_DIR/../dist

cp -rf $SCRIPT_DIR/../native_ability/src/main/ets/ $SCRIPT_DIR/../package/src/main/ets

pushd $SCRIPT_DIR/../ && ohrs artifact --skip-libs

# Fix package/LICENSE if it's a broken reference (e.g., contains "../LICENSE" instead of actual text)
if head -1 $SCRIPT_DIR/../package/LICENSE 2>/dev/null | grep -q '^\.\./'; then
  cp -f $SCRIPT_DIR/../LICENSE $SCRIPT_DIR/../package/LICENSE
  echo "Fixed package/LICENSE (was a broken reference)"
fi