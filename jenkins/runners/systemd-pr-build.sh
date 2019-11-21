#!/bin/sh

# Note: this script MUST be self-contained - i.e. it MUST NOT source any
# external scripts as it is used as a bootstrap script, thus it's
# fetched and executed without rest of this repository
#
# Example usage in Jenkins
# #!/bin/sh
#
# set -e
#
# curl -q -o runner.sh https://../systemd-pr-build.sh
# chmod +x runner.sh
# ./runner.sh

# Add a local ~/bin dir to path for custom binaries (currently used only
# for the tree binary for generating the artifact landing page)
export PATH="/home/systemd/bin:$PATH"
ARGS=

set -e
set -o pipefail

if [ "$ghprbPullId" ]; then
    ARGS="$ARGS --pr $ghprbPullId "

    # We're not testing the master branch, so let's see if the PR scope
    # is something we should indeed test
    git clone https://github.com/systemd/systemd systemd-tmp && cd systemd-tmp
    git fetch -fu origin "refs/pull/$ghprbPullId/head:pr"
    git checkout pr
    # Let's make the regex here less strict, so we can, for example, test man page
    # generation and other low-impact changes
    SCOPE_RX='(^(catalog|factory|hwdb|man|meson.*|network|[^\.].*\.d|rules|src|test|tools|units))'
    if ! git diff $(git merge-base master pr) --name-only | grep -E "$SCOPE_RX" ; then
        echo "Changes in this PR don't seem relevant, skipping..."
        exit 0
    fi
    cd .. && rm -fr systemd-tmp
fi

git clone https://github.com/systemd/systemd-centos-ci
cd systemd-centos-ci

./agent-control.py --version 8 $ARGS
