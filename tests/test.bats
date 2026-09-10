#!/usr/bin/env bats

# Bats is a testing framework for Bash
# Documentation https://bats-core.readthedocs.io/en/stable/
# Bats libraries documentation https://github.com/ztombol/bats-docs

# For local tests, install bats-core, bats-assert, bats-file, bats-support
# And run this in the add-on root directory:
#   bats ./tests/test.bats
# To exclude release tests:
#   bats ./tests/test.bats --filter-tags '!release'
# For debugging:
#   bats ./tests/test.bats --show-output-of-passing-tests --verbose-run --print-output-on-failure

setup() {
  set -eu -o pipefail

  # Override this variable for your add-on:
  export GITHUB_REPO=ddev/ddev-pnpm

  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  bats_load_library bats-assert
  bats_load_library bats-file
  bats_load_library bats-support

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export PROJNAME="test-$(basename "${GITHUB_REPO}")"
  mkdir -p "${HOME}/tmp"
  export TESTDIR="$(mktemp -d "${HOME}/tmp/${PROJNAME}.XXXXXX")"
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"
  run ddev config --project-name="${PROJNAME}" --project-tld=ddev.site
  assert_success
  run ddev start -y
  assert_success

  export HAS_PNPM_DIRECTORY=false
}

health_checks() {
  # Verify $PNPM_HOME is prepended to $PATH. The exact directory depends on the
  # pnpm major version (see web-build/Dockerfile.pnpm): pnpm v11+ uses
  # $PNPM_HOME/bin, older versions use $PNPM_HOME directly.
  run ddev pnpm -v
  assert_success

  pnpm_version="${output#v}"
  if [[ "${pnpm_version%%.*}" -ge 11 ]]; then
    expected_path="/mnt/ddev-global-cache/pnpm/bin"
  else
    expected_path="/mnt/ddev-global-cache/pnpm"
  fi

  run ddev exec 'echo ":$PATH:"'
  assert_success
  assert_output --partial ":${expected_path}:"

  run ddev pnpm store path
  assert_success
  assert_output --partial "/mnt/ddev-global-cache/pnpm"

  if [[ "${HAS_PNPM_DIRECTORY}" == "true" ]]; then
    run ddev pnpm test
    assert_success
    assert_output --partial "directory=frontend"
  else
    run ddev pnpm init
    assert_success
    assert_file_exist package.json
  fi

  # Verify the global cache is populated after install and reused across directories.
  run ddev exec rm -rf /mnt/ddev-global-cache/pnpm
  assert_success

  mkdir "${TESTDIR}/cache-first"
  cp "${DIR}/tests/testdata/frontend/package.json" "${TESTDIR}/cache-first/package.json"
  run ddev exec bash -c "cd /var/www/html/cache-first && pnpm install"
  assert_success

  # Verify packages actually landed in the global cache, not some other store
  run ddev exec bash -c "find /mnt/ddev-global-cache/pnpm -type f | wc -l"
  assert_success
  (( output > 0 ))

  # Install the same package version from a second directory and verify it is
  # fully satisfiable from the global cache alone, with no network access
  mkdir "${TESTDIR}/cache-second"
  cp "${DIR}/tests/testdata/frontend/package.json" "${TESTDIR}/cache-second/package.json"

  run ddev exec bash -c "cd /var/www/html/cache-second && pnpm install --offline"
  assert_success

  run ddev exec bash -c "cd /var/www/html/cache-second && pnpm list 2>&1 | grep 'is-odd'"
  assert_success
  assert_output --partial "3.0.1"

  # Install a different version of the same package: the cache alone is not
  # enough, so an offline install must fail, but a normal install succeeds
  # and pulls the new version
  mkdir "${TESTDIR}/cache-third"
  printf '{"name":"third","version":"1.0.0","dependencies":{"is-odd":"2.0.0"}}' > "${TESTDIR}/cache-third/package.json"

  run ddev exec bash -c "cd /var/www/html/cache-third && pnpm install --offline"
  assert_failure

  run ddev exec bash -c "cd /var/www/html/cache-third && pnpm install"
  assert_success

  run ddev exec bash -c "cd /var/www/html/cache-third && pnpm list 2>&1 | grep 'is-odd'"
  assert_success
  assert_output --partial "2.0.0"

  run ddev pnpm link .
  assert_success
}

teardown() {
  set -eu -o pipefail
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1
  # Persist TESTDIR if running inside GitHub Actions. Useful for uploading test result artifacts
  # See example at https://github.com/ddev/github-action-add-on-test#preserving-artifacts
  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV:-}" ] && echo "TESTDIR=${HOME}/tmp/${PROJNAME}" >> "${GITHUB_ENV}"
  else
    [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}"
  fi
}

@test "install from directory" {
  set -eu -o pipefail
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
}

# bats test_tags=release
@test "install from release" {
  set -eu -o pipefail
  echo "# ddev add-on get ${GITHUB_REPO} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${GITHUB_REPO}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
}

@test "use ENV to set working directory" {
  set -eu -o pipefail

  export HAS_PNPM_DIRECTORY=true

  # Create a frontend project
  cp -r "${DIR}/tests/testdata/frontend" "${TESTDIR}/frontend"

  # Set the PNPM_DIRECTORY to match our frontend project
  run ddev dotenv set .ddev/.env.web --pnpm-directory=frontend
  assert_success
  assert_file_exist .ddev/.env.web

  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
}

@test "latest Node.js" {
  set -eu -o pipefail

  ddev config --nodejs-version=latest
  assert_success

  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
}

@test "v20 Node.js" {
  set -eu -o pipefail

  ddev config --nodejs-version=20
  assert_success

  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
}
