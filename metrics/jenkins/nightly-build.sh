#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

export KUBE_SKIP_UPDATE="y"
export KUBE_PROMPT_FOR_UPDATE="N"

: ${ENV_SCRIPT_DIR:?"Need to set ENV_SCRIPT_DIR"}
: ${PUBLISHER_DIR:?"Need to set PUBLISHER_DIR"}
# Assumes that most of the time we run nightly builds in k8s repo
K8S_DIR=${K8S_DIR:-`pwd`}

# Used to tell if e2e test has been run successfully.
# Note that if e2e test wasn't run, it's seen as a failure.
# The script will exit 1 if e2e_test_succeed != "y". We use this in Jenkins to notify result.
e2e_test_succeed="n"

TEMPDIR=$(mktemp -d 2>/dev/null || mktemp -d -t metrics-publisher.XXXXXX)

cleanup() {
  rm -rf "${TEMPDIR}"
  (source "${ENV_SCRIPT_DIR}/kubemark-env.sh" && ${K8S_DIR}/test/kubemark/stop-kubemark.sh) || true
  (source "${ENV_SCRIPT_DIR}/k8s-cluster-env.sh" && ${K8S_DIR}/cluster/kube-down.sh) || true

  exitCode="0"
  if [ "x${e2e_test_succeed}" != "xy" ]; then
    exitCode="1"
  fi
  exit "${exitCode}"
}

trap cleanup EXIT

source "${ENV_SCRIPT_DIR}/k8s-cluster-env.sh" && ${K8S_DIR}/cluster/kube-up.sh

source "${ENV_SCRIPT_DIR}/kubemark-env.sh" && ${K8S_DIR}/test/kubemark/start-kubemark.sh
# If test succeeded, the log file is named "kubemark-log.txt"
# If test succeeded, the log file is named "kubemark-log-fail.txt"
kubemark_log_file="kubemark-log.txt"
("${K8S_DIR}/test/kubemark/run-e2e-tests.sh" --ginkgo.focus="should\sallow\sstarting\s30\spods\sper\snode" --delete-namespace="false" --gather-resource-usage="false" \
  | tee "${TEMPDIR}/${kubemark_log_file}") || true

# For some reason, we can't trust e2e test script exit code
if [ "x$(tail -n 1 ${TEMPDIR}/${kubemark_log_file})" == "xTest Suite Passed" ]; then
  e2e_test_succeed="y"
fi

echo "e2e test succeeded? ${e2e_test_succeed}"

if [ -f "${TEMPDIR}/${kubemark_log_file}" ]; then
  if [ "x${e2e_test_succeed}" != "xy" ]; then
    fail_kubemark_log_file="kubemark-log-fail.txt"
    mv "${TEMPDIR}/${kubemark_log_file}" "${TEMPDIR}/${fail_kubemark_log_file}"
    kubemark_log_file=${fail_kubemark_log_file}
  fi
  source "${ENV_SCRIPT_DIR}/publisher-env.sh" && \
    KUBEMARK_LOG_FILE="${TEMPDIR}/${kubemark_log_file}" "${PUBLISHER_DIR}/publish.sh"
fi
