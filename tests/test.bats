setup() {
  set -eu -o pipefail

  export DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )/.."
  export TESTDIR=~/tmp/ddev-pnpm
  mkdir -p $TESTDIR
  export PROJNAME=ddev-pnpm
  export DDEV_NON_INTERACTIVE=true
  ddev delete -Oy ${PROJNAME} || true
  cd "${TESTDIR}"
  ddev config --project-name=${PROJNAME}
  ddev start
}

health_checks() {
  run ddev pnpm --version
}

teardown() {
  set -eu -o pipefail
  cd ${TESTDIR} || ( printf "unable to cd to ${TESTDIR}\n" && exit 1 )
  ddev delete -Oy ${PROJNAME}
  [ "${TESTDIR}" != "" ] && rm -rf ${TESTDIR}
}

@test "install from directory" {
  set -eu -o pipefail
  cd ${TESTDIR}
  echo "# ddev get ${DIR} with project ${PROJNAME} in ${TESTDIR} ($(pwd))" >&3
  ddev get ${DIR}
  ddev restart
  health_checks
}

@test "install from release" {
  set -eu -o pipefail
  cd ${TESTDIR} || ( printf "unable to cd to ${TESTDIR}\n" && exit 1 )
  echo "# ddev get envsa/ddev-pnpm with project ${PROJNAME} in ${TESTDIR} ($(pwd))" >&3
  ddev get envsa/ddev-pnpm
  ddev restart
  health_checks
}

@test "use ENV to set working directory" {
  set -eu -o pipefail
  cd ${TESTDIR} || ( printf "unable to cd to ${TESTDIR}\n" && exit 1 )
  echo "# ddev get ${DIR} with project ${PROJNAME} in ${TESTDIR} ($(pwd))" >&3
  ddev get ${DIR}

  # Create a frontend prject
  cp ${DIR}/tests/testdata/frontend ${TESTDIR}/frontend -r

  # Set the PNPM_DIRECTORY to match our frontend project
  echo PNPM_DIRECTORY=frontend > ./.ddev/.env

  # Restart DDEV to apply the .env settings
  ddev restart

  # Confirm it can run the script
  ddev pnpm test | grep 'directory=frontend'
}
