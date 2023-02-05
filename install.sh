#!/bin/bash
# A script to fetch, patch, build, and install suckless tools.
#
# Example usage:
#   - ./install.sh --install_deps # install deps && install everything
#   - ./install.sh # dl, patch, install all progs below
#   - ./install.sh --add_patch slock-git-20161012-control-clear.diff
#
# TODO:
#   - add dwmblocks build dependencies OR try out suckless slstatus
#   - add slock and xssstate for screensaver/lockscreen
#   - update sysconfig script to use this
#
# Tools are split into dedicated directories with layouts like:
#   - upstream/ : upstream source as a git submodule
#   - patches/  : patches for that tool
#     - series    : a file describing path order (read by quilt)
#     - myconfig  : a patch containing my personal tweaks
#
# Quilt tips (https://tools.ietf.org/doc/quilt/quilt.html is good):
#   - Run in trace mode for debug:
#     - quilt --trace push
#   - View current patches:
#     - quilt applied/unapplied
#   - Resolve a conflicting patch:
#     - quilt push
#     - quilt push -f
#     - <view conflicts in $file.rej files, resolve in $file>
#     - quilt refresh
#     - rm *.rej
#   - Create a new patch:
#     - quilt new myPatch.diff
#     - quilt add file_to_modify
#     - quilt edit file_to_modify
#     - quilt refresh    << updates the patch from the diff
#     - quilt header -e  << set patch header
#     - quilt pop a      << reset, remove all patches
#   - Unapply a patch:
#     - quilt pop  (-f if aborting a force push, -a to revert all)
#   - Reorder patches:
#     - quilt pop -a
#     - <change order in series file>
#     - quilt push -a
#
# Weird Issues:
#   - This can happen if I accidently commit to a submodule:
#   - To prevent, don't 'git commit' within upstream dirs.
#   - "error: Server does not allow request for unadvertised object"
#   - =>git reset --hard HEAD~1
#   - =>git submodule foreach --recursive git checkout master
set -euo pipefail
# set -x # for debug

BASEDIR="$(cd `dirname "$0"` &>/dev/null && pwd)"
sl_root=git://git.suckless.org
sl_patch_root=https://dwm.suckless.org/patches/
dwmblocks_root=git://github.com/torrinfail

declare -a deps=(
  # dmenu
  libxinerama-dev
  libxft-dev
  # dwm
  libx11-dev
  libx11-xcb-dev
  libxcb-res0-dev
  # slock
  libxrandr-dev
  # xssstate
  libxss-dev
  # sent
  farbfeld
)

function add_patch() {
  # TODO pattern not always the same, e.g. slock-git-20161012-control-clear.diff
  #  => Should probably just accept a url here instead of patch name
  # TODO the filenames in the downloaded patch aren't right (replace a|b with
  # upstream). Maybe there's a quilt trick for this? or -p flag? or something
  # that doesn't require text replacements in the patch file.
  declare -r patch=${1}
  declare -r prog=${1%%-*} # rstrip longest matching substring matching -*
  patch_name=${1#*-} # lstrip shortest matching substring
  patch_name=${patch_name%%-*}
  # example patch name: dwm-pertag-20200914-61bb8b2.diff

  server=${prog}.suckless.org
  if ! ping -c 1 $server &>/dev/null; then
    # subdomain might be 'tools' (for the smaller projects)
    server=tools.suckless.org
  fi
  url=https://${server}/patches/${patch_name}/${patch}
  [ -d ${BASEDIR}/${prog}/patches ] || { echo "${prog} not initialized yet"; return 1; }
  cd ${BASEDIR}/${prog}/patches
  [ -f series ] || { echo "${prog} series file not initialized yet"; return 1; }
  if grep -q ${patch} series; then
    echo "$patch already present in patches/series file"
    return 1
  fi

  echo "downloading patch"
  set +e
  curl --fail -s -O $url
  if [ $? -ne 0 ]; then
    echo "failed to download patch $url"
    return 1
  fi
  echo "${patch} -p0" >> series
  echo "applying patch"
  quilt push &>/dev/null
  if [ $? -ne 0 ]; then
    echo "failed to apply patch - run 'quilt push -f', resolve rejects, and refresh the patch"
    return 1
  fi
  set -e
  echo "success - patch applied!"
  cd ${BASEDIR}/${prog}/upstream
  make clean install >/dev/null
  if [ $? -ne 0 ]; then
    echo "failed to rebuild ${prog}"
    make clean >/dev/null
    return 1
  fi
  make clean >/dev/null
  echo "reinstalled ${prog} to pickup ${patch_name}"
}

if [ ${1-""} == "--install_deps" ]; then
  # too lazy for getopts
  shift
  echo "installing required dependencies"
  DEBIAN_FRONTEND=noninteractive sudo apt-get install -y ${deps[@]}
elif [ ${1-""} == "--add_patch" ]; then
  shift
  patch=${1?"must provide patch name"}
  shift
  add_patch ${patch}
  exit
fi

declare -a progs=(
  dmenu
  dwm
  dwmblocks
  sent
  slock
  st
  xssstate
)

git submodule update --init --recursive &>/dev/null

for p in ${progs[@]}; do
  dir="${BASEDIR}"/$p
  up=${sl_root}/$p
  if [ $p = dwmblocks ]; then
    up=${dwmblocks_root}/$p
  fi

  # 1. Clone
  [ -d $dir ] || mkdir $dir &>/dev/null
  cd $dir
  # Note: submodules have a .git file - not a dir
  if [ ! -f upstream/.git ]; then
    echo "[$p] cloning"
    git submodule add --force --name $p ${up} upstream
    #git submodule add --force --name $p ${up} upstream &>/dev/null
  fi

  # 2. Patch
  [ -d patches ] || mkdir patches &>/dev/null
  if [ ! -f patches/series ]; then
    # Largest patch first. Highly unlikely this works out perfect w/o intervention.
    # Append -p0 which allows the directory structure to work properly.
    # Note: You will still have to change filenames in the patch itself!
    ls -S patches --hide series --ignore '*~' | sed 's/$/ -p0/' >> patches/series
  fi
  if [ -f upstream/config.mk -a ! -f patches/config-mk.diff ]; then
    # Add a patch to set the install directory.
    quilt new -p0 config-mk.diff &>/dev/null
    quilt add upstream/config.mk &>/dev/null
    sed -i '/^PREFIX =/c\PREFIX = \$(HOME)/.local' upstream/config.mk
    quilt refresh &>/dev/null
    quilt pop &>/dev/null
  fi
  echo "[$p] patching"
  set +e
  quilt pop -a -f &>/dev/null
  quilt push -a &>/dev/null
  # ret code 2 means 'already fully patched', 1 is err
  if [ $? -eq 1 ]; then
    echo "[$p] patching FAILED - run 'quilt push -a' to see"
    quilt pop -a &>/dev/null
    exit 1
  fi
  set -e
  echo -e "[$p] patching complete:\n`quilt series | sed 's/^/\t/'`"

  # 3. Install
  cd ${dir}/upstream
  echo "[$p] installing"
  rm -f config.h
  make clean install >/dev/null
  make clean >/dev/null
  echo "[$p] install complete"

  echo "-----------"
done

