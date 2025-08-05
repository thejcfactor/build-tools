#!/bin/bash -ex

# example usage
# get_source.sh couchbase-analytics-sdk-python 1.0.0 1.0.0 9999

# Set to "couchbase-analytics-sdk-python", ignored in this script.
PRODUCT=$1
# By default this will be the same as VERSION; however, if your scan-config.json specified a release key for this version,
# that value will be passed here
RELEASE=$2
# Onee of the version keys from scan-config.json.
VERSION=$3
# Set to 9999, ignored in this script as it is not useful for SDK scans.
BLD_NUM=$4

TARBALL="couchbase-analytics-${VERSION}.tar.gz"
SOURCE_DIR=analytics-python-client

# Lets only use git if we cannot find the source tarball on PyPI.
# Would be nice to ignore build isolation (--no-build-isolation), but the pip resolver
# does not want to play nice and it does not impact the scan.  Maybe a nice-to-have in the future.
python -m pip download --no-deps --no-binary couchbase-analytics --no-cache-dir couchbase-analytics==$VERSION || true
if [ ! -f "${TARBALL}" ]; then
    if [ "$RELEASE" == "$VERSION" ] || [ "$RELEASE" == "master" ]; then
        RELEASE="main"
    fi
    echo "Version $VERSION does not exist on PyPI, checking out git repository and building sdist."
    git clone https://github.com/couchbaselabs/analytics-python-client $SOURCE_DIR
    pushd $SOURCE_DIR
    git checkout $RELEASE
    python -m pip install --upgrade setuptools
    mkdir sdist
    python setup.py sdist -d sdist
    TARBALL=$(find sdist -type f -name "*.tar.gz")
    TARBALL=$(echo $TARBALL | cut -c 7-)
    popd
    mv $SOURCE_DIR/sdist/$TARBALL .
    rm -rf $SOURCE_DIR
fi

tar -xvf $TARBALL
mkdir $SOURCE_DIR
TARBALL_CONTENTS_DIR=$(echo $TARBALL | rev | cut -c 8- | rev)
mv $TARBALL_CONTENTS_DIR/* $SOURCE_DIR

# Since our source tarball includes a setup.py and requirements.txt the BD
# detector search will satisfy the HIGH accuracy requirement
# SEE: https://documentation.blackduck.com/bundle/detect/page/components/detectors.html
rm -rf $TARBALL_CONTENTS_DIR
rm $TARBALL

# Need to keep git for SDK's version file to work
export KEEP_GIT=true
