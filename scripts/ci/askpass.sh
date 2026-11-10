#!/bin/sh
# Used as GIT_ASKPASS so the token never appears in a URL or a command line.
case "$1" in
  Username*) echo "$GIT_USER" ;;
  *) echo "$GIT_TOKEN" ;;
esac
