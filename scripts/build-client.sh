#!/usr/bin/env bash
#
# Builds packages/apps/client (Visual C++) from inside WSL2, with no Windows-side
# MSBuild: the real MSVC v142 toolchain runs under Wine via msvc-wine.
#
# One-time setup per machine: docs/setup-client-wsl2.md
# Why it is shaped this way:   docs/researchs/wsl2-client-build-watcher.md (§11)
#
# Set MSVC_ROOT if the toolchain is not at ~/msvc.

set -euo pipefail

MSVC_ROOT="${MSVC_ROOT:-$HOME/msvc}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLN="$REPO_ROOT/packages/apps/client/TM.sln"

if [ ! -x "$MSVC_ROOT/bin/x86/msbuild" ]; then
  echo "No msvc-wine toolchain at $MSVC_ROOT — see docs/setup-client-wsl2.md" >&2
  exit 1
fi

# BASE / MSVCBASE / MSVCDIR, as Wine-visible z: paths.
# shellcheck source=/dev/null
source "$MSVC_ROOT/bin/x86/msvcenv.sh"

# The msvc-wine msbuild wrapper exports VCInstallDir_180 / VCToolsInstallDir_180 (VS2022
# naming), but the v160 props this toolset ships read the _160 names.
export VCInstallDir_160="$MSVCBASE\\"
export VCToolsInstallDir_160="$MSVCDIR\\"

# The MSBuild engine is VS2022, so $(VCTargetsPath) defaults to v170, which is not installed.
VCTARGETS_UNIX="$(echo "$MSVC_ROOT"/MSBuild/Microsoft/VC/v1*/ | tail -n1)"
export VCTargetsPath="z:${VCTARGETS_UNIX//\//\\}"

# Solution-level platform is x86 (it maps to the project's Release|Win32); Release|Win32 is
# also the only config whose IncludePath puts $(IncludePath) ahead of the vendored 2002
# DirectX headers, whose basetsd.h otherwise shadows the SDK's and breaks <windows.h>.
# -nr:false: no lingering worker nodes to outlive a watcher restart.
exec "$MSVC_ROOT/bin/x86/msbuild" "$SLN" \
  -p:Configuration="${CONFIGURATION:-Release}" \
  -p:Platform=x86 \
  -m -nr:false -noAutoResponse -v:m "$@"
