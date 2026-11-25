#!/bin/zsh
# Compile the API's contract, equities.proto from lib (equities/api/proto),
# into Swift: Proto/ gets a copy, Sources/Optimates/Generated its messages
# (swift-protobuf). Commit both. The calls themselves are Series.swift's
# `Method`s, one per rpc of the .proto's service.
#
#     ./proto.sh [LIB]      LIB: a checkout of atecce/lib (default ~/lib)
#     ./proto.sh --keep     regenerate from Proto/ as committed (Xcode Cloud)
#
# The generator is built from the swift-protobuf Package.swift pins, the one
# the app links, so generated code and runtime always match. Needs protoc
# 3.15 or later (brew install protobuf).

lib=${1:-$HOME/lib}
keep=; [ "$1" = --keep ] && keep=1
# The directory this script is in.
cd ${0:A:h} || exit 1

# libprotoc 3.6.1 is too old for proto3 optional; versions since 3.21 are
# numbered 21, 22, ...
version=$(protoc --version 2>/dev/null | awk '{print $2}')
case $version in
  3.<0-14>.*|"") echo "protoc ${version:-missing}: needs 3.15 or later (brew install protobuf)" >&2; exit 1 ;;
esac

proto=equities/v1/equities.proto
if [ -z "$keep" ]; then
  [ -f $lib/equities/api/proto/$proto ] || { echo "no $lib/equities/api/proto/$proto" >&2; exit 1 }
  mkdir -p Proto/${proto:h} && cp $lib/equities/api/proto/$proto Proto/$proto || exit 1
fi

swift build -c release --product protoc-gen-swift -q || exit 1
bin=$(swift build -c release --show-bin-path)

out=Sources/Optimates/Generated
rm -rf $out && mkdir -p $out
protoc -I Proto \
  --plugin=protoc-gen-swift=$bin/protoc-gen-swift \
  --swift_out=$out --swift_opt=Visibility=Internal,FileNaming=DropPath \
  Proto/$proto || exit 1
ls $out
