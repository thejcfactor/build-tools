#!/bin/bash -e

function usage() {
    echo
    echo "$0 -r <release-code-name> -v <version-number> -b <build-number>"
    echo "   [-t <product>] [-s <suffix> ] [-c <private | public | only>]"
    echo "   [-p <platforms>] [-l]"
    echo "where:"
    echo "  -r: release code name; mad-hatter; cheshire-cat; etc."
    echo "  -v: version number; eg. 7.0.0"
    echo "  -b: build number to release"
    echo "  -t: product; defaults to couchbase-server"
    echo "  -s: version suffix, eg. 'MP1' or 'beta' [optional]"
    echo "  -c: how to handle CE builds [optional]. Legal values are:"
    echo "        private: to make it non-downloadable (default)"
    echo "        public: CE builds are downloadable"
    echo "        only: only upload CE (implies public)"
    echo "        none: do NOT upload CE [optional]"
    echo "  -p: specific platforms to upload. By default uploads all platforms."
    echo "      Pass -p multiple times for multiple platforms [optional]"
    echo "  -l: Push it to live (production) s3. Default is to push to staging [optional]"
    echo
}

DEFAULT_PLATFORMS=(ubuntu amzn2 centos debian rhel macos oel suse windows linux)
MP=
LIVE=false

# Set to "private" to keep community builds non-downloadable
COMMUNITY=private

# Default product
PRODUCT=couchbase-server

while getopts "r:v:V:b:t:s:c:p:lh?" opt; do
    case $opt in
        r) RELEASE=$OPTARG;;
        v) VERSION=$OPTARG;;
        b) BUILD=$OPTARG;;
        t) PRODUCT=$OPTARG;;
        s) SUFFIX=$OPTARG;;
        c) COMMUNITY=$OPTARG;;
        p) PLATFORMS+=("$OPTARG");;
        l) LIVE=true;;
        h|?) usage
           exit 0;;
        *) echo "Invalid argument $opt"
           usage
           exit 1;;
    esac
done

if [ ${#PLATFORMS[@]} -eq 0 ]; then
    PLATFORMS=("${DEFAULT_PLATFORMS[@]}")
fi

if [ "x${RELEASE}" = "x" ]; then
    echo "Release code name not set"
    usage
    exit 2
fi

if [ "x${VERSION}" = "x" ]; then
    echo "Version number not set"
    usage
    exit 2
fi

if [ "x${BUILD}" = "x" ]; then
    echo "Build number not set"
    usage
    exit 2
fi

if ! [[ $VERSION =~ ^[0-9]*\.[0-9]*\.[0-9]*$ ]]
then
    echo "Version number format incorrect. Correct format is A.B.C where A, B and C are integers."
    exit 3
fi

if ! [[ $BUILD =~ ^[0-9]*$ ]]
then
    echo "Build number must be an integer"
    exit 3
fi

RELEASES_MOUNT=/releases
if [ ! -e ${RELEASES_MOUNT} ]; then
    echo "'releases' directory is not mounted"
    exit 4
fi

LB_MOUNT=/latestbuilds
if [ ! -e ${LB_MOUNT} ]; then
    echo "'latestbuilds' directory is not mounted"
    exit 4
fi


# Compute target filename component
if [ -z "$SUFFIX" ]
then
    RELEASE_DIRNAME=$VERSION
    FILENAME_VER=$VERSION
else
    RELEASE_DIRNAME=$VERSION-$SUFFIX
    FILENAME_VER=$VERSION-$SUFFIX
fi

# Add product super-directory, if not couchbase-server
if [[ "${PRODUCT}" != "couchbase-server" ]]
then
    RELEASE_DIRNAME=${PRODUCT}/${RELEASE_DIRNAME}
fi

# Compute destination directories
ROOT=s3://packages-staging.couchbase.com/releases/$RELEASE_DIRNAME
RELEASE_DIR=${RELEASES_MOUNT}/staging/$RELEASE_DIRNAME

if [[ "$LIVE" = "true" ]]
then
    S3CONFIG=~/.ssh/live.s3cfg
    ROOT=s3://packages.couchbase.com/releases/$RELEASE_DIRNAME
    RELEASE_DIR=${RELEASES_MOUNT}/$RELEASE_DIRNAME
fi

# Create destination directory
mkdir -p $RELEASE_DIR

upload()
{
    echo ::::::::::::::::::::::::::::::::::::::

    if [[ "$COMMUNITY" == "private" ]]
    then
        echo Uploading ${RELEASE_DIRNAME} ...
        echo CE are uploaded PRIVATELY ...
        perm_arg="private"
        aws s3 sync ${UPLOAD_TMP_DIR} ${ROOT}/ --acl private --exclude "*" --include "*community*"
        aws s3 sync ${UPLOAD_TMP_DIR} ${ROOT}/ --acl public-read --exclude "*community*"
    else
        echo Uploading ${RELEASE_DIRNAME} ...
        aws s3 sync ${UPLOAD_TMP_DIR} ${ROOT}/ --acl public-read
    fi

    echo Copying ${UPLOAD_TMP_DIR} to ${RELEASE_DIR} ...
    rsync -a ${UPLOAD_TMP_DIR}/* ${RELEASE_DIR}/
}

OPWD=`pwd`
finish() {
    cd $OPWD
    exit
}
trap finish EXIT

if [ ! -e ${LB_MOUNT}/${PRODUCT}/$RELEASE/$BUILD ]; then
    echo "Given build doesn't exist: ${LB_MOUNT}/${PRODUCT}/$RELEASE/$BUILD"
    exit 5
fi

#prepare files to be uploaded
UPLOAD_TMP_DIR=/tmp/${PRODUCT}-${RELEASE}-${BLD_NUM}
rm -rf ${UPLOAD_TMP_DIR} && mkdir -p ${UPLOAD_TMP_DIR}

cd ${LB_MOUNT}/${PRODUCT}/$RELEASE/$BUILD

# Copy manifest and notices.txt to release directory
cp ${PRODUCT}-${VERSION}-${BUILD}-manifest.xml ${UPLOAD_TMP_DIR}/${PRODUCT}-${VERSION}-manifest.xml
NOTICES_FILE=blackduck/${PRODUCT}-${VERSION}-${BUILD}-notices.txt
if [ -e ${NOTICES_FILE} ]; then
    cp ${NOTICES_FILE} ${UPLOAD_TMP_DIR}/${PRODUCT}-${VERSION}-notices.txt
fi

# For Server 7.2.0 and up, at the moment we produce some installers that we
# don't want to ship. Filter those out.
if [ "7.2.0" = $(printf "7.2.0\n${VERSION}" | sort -n | head -1) ]; then
    SKIP_PLATFORMS=(centos7 oel7 rhel7 ubuntu18.04)
fi
for skip in ${SKIP_PLATFORMS[@]}; do
    EXTRA_FIND_ARGS="${EXTRA_FIND_ARGS} -not -name *${skip}*"
done

for platform in ${PLATFORMS[@]}
do
    # Have to disable bash's filename expansion here (with "set -f") -
    # doesn't seem to be any other way to pass EXTRA_FIND_ARGS to find
    # without bash expanding the glob wildcards first
    for file in $( \
        set -f; \
        find . -maxdepth 1 \( \
            -name *${PRODUCT}*${platform}* \
            -not -name *unsigned* \
            -not -name *unnotarized* \
            -not -name *asan* \
            -not -name *.md5 \
            -not -name *.sha26 \
            -not -name *.properties \
            ${EXTRA_FIND_ARGS} \
        \) )
    do
        # Remove leading "./" from find results
        file=${file/.\//}

        # "artifact" is the filename with the build number stripped out
        artifact=${file/$VERSION-$BUILD/$FILENAME_VER}

        # Handle various options for CE artifacts
        if [[ "$COMMUNITY" == "none" && "${artifact}" =~ "community" ]]
        then
            echo "COMMUNITY=none set, skipping ${artifact}"
            continue
        fi
        if [[ "$COMMUNITY" == "only" && ! "${artifact}" =~ "community" ]]
        then
            echo "COMMUNITY=only set, skipping ${artifact}"
            continue
        fi

        # Copy artifact to release mirror and create checksum file
        echo Copying ${artifact}
        cp $file ${UPLOAD_TMP_DIR}/${artifact}
        echo Creating fresh sha256sum file for ${artifact}
        sha256sum ${UPLOAD_TMP_DIR}/${artifact} | cut -c1-64 > ${UPLOAD_TMP_DIR}/${artifact}.sha256
    done
done

upload
rm -rf ${UPLOAD_TMP_DIR}
