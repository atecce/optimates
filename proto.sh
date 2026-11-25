#!/bin/zsh
# Compile the API's contract, equities.proto from lib (equities/api/proto),
# into Swift: Proto/ gets a copy, Sources/Optimates/Generated the messages
# (swift-protobuf) and the client (connect-swift). Commit all three.
#
#     ./proto.sh [LIB]      LIB: a checkout of atecce/lib (default ~/lib)
#
# The generators are built from the packages Package.swift pins, the same
# the app links, so generated code and runtime always match. Needs protoc.

lib=${1:-$HOME/lib}
# The directory this script is in.
cd ${0:A:h} || exit 1

proto=equities/v1/equities.proto
[ -f $lib/equities/api/proto/$proto ] || { echo "no $lib/equities/api/proto/$proto" >&2; exit 1 }
mkdir -p Proto/${proto:h} && cp $lib/equities/api/proto/$proto Proto/$proto || exit 1

for generator in protoc-gen-swift protoc-gen-connect-swift; do
  swift build -c release --product $generator -q || exit 1
done
bin=$(swift build -c release --show-bin-path)

out=Sources/Optimates/Generated
rm -rf $out && mkdir -p $out
protoc -I Proto \
  --plugin=protoc-gen-swift=$bin/protoc-gen-swift \
  --plugin=protoc-gen-connect-swift=$bin/protoc-gen-connect-swift \
  --swift_out=$out --swift_opt=Visibility=Internal,FileNaming=DropPath \
  --connect-swift_out=$out \
  --connect-swift_opt=Visibility=Internal,FileNaming=DropPath,GenerateAsyncMethods=true,GenerateCallbackMethods=false \
  Proto/$proto || exit 1
ls $out
