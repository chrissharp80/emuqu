# shellcheck shell=bash
#
# The flag that holds every xcodebuild run to the committed package versions.
#
# `Emuqu.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
# is committed, and testflight.yml records its hash beside each archive. Without
# this flag xcodebuild may resolve the packages again and build against versions
# the file does not name; with it, a build whose Package.resolved no longer
# satisfies the project's package requirements fails instead.
#
# One definition for every caller:
#
#   * scripts source this file and pass "$XCODEBUILD_PINNED";
#   * the Makefile includes it and passes $(XCODEBUILD_PINNED), so it holds only
#     NAME=value lines, which read the same in bash and make;
#   * workflow steps that call xcodebuild inline pass the flag literally and
#     name this file beside it.
#
# `check_xcodebuild_pinned.sh` fails any xcodebuild invocation in the Makefile,
# a workflow or a script that loads the project without it.
XCODEBUILD_PINNED=-onlyUsePackageVersionsFromResolvedFile
