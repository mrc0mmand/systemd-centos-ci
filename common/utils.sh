#!/usr/bin/bash
# This file contains useful functions shared among scripts from this repository

# Checkout to the requsted branch:
#   1) if pr:XXX where XXX is a pull request ID is passed to the script,
#      the corresponding branch for this PR is be checked out
#   2) if any other string except pr:* is passed, it's used as a branch
#      name to check out
#   3) if the script is called without arguments, the default (possibly master)
#      branch is used
git_checkout_pr() {
    echo "[$FUNCNAME] Arguments: $*"
    (
        set -e -u
        case $1 in
            pr:*)
                # Draft and already merged pull requests don't have the 'merge'
                # ref anymore, so fall back to the *standard* 'head' ref in
                # such cases and rebase it against the master branch
                if ! git fetch -fu origin "refs/pull/${1#pr:}/merge:pr"; then
                    git fetch -fu origin "refs/pull/${1#pr:}/head:pr"
                    git rebase master pr
                fi

                git checkout pr
                ;;
            "")
                ;;
            *)
                git checkout "$1"
                ;;
        esac
    ) || return 1

    # Initialize git submodules, if any
    git submodule update --init --recursive

    echo -n "[$FUNCNAME] Checked out version: "
    git describe
    git log -1
}

# Check input from stdin for sanitizer errors/warnings
# Takes no arguments, reads input directly from stdin to allow piping, like:
#   journalctl -b | check_for_sanitizer_errors
check_for_sanitizer_errors() {
    awk '
    BEGIN {
        asan_cnt = 0;
        ubsan_cnt = 0;
        msan_cnt = 0;
        total_cnt = 0;
    }

    match($0, /SUMMARY:\s+(\w+)Sanitizer/, m) {
        total_cnt++;

        switch (m[1]) {
        case "Address":
            asan_cnt++;
            break;
        case "UndefinedBehavior":
            ubsan_cnt++;
            break;
        case "Memory":
            msan_cnt++;
            break;
        }
    }

    END {
        if (total_cnt != 0) {
            printf "Found %d sanitizer errors (%d ASan, %d UBSan, %d MSan)\n", \
                total_cnt, asan_cnt, ubsan_cnt, msan_cnt;
            exit 1
        }
    }
    '
}
