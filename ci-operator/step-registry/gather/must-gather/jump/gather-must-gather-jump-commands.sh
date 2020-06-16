#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export HOME=/tmp
export WORKSPACE=${WORKSPACE:-/tmp}
export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey

# This must match exactly to the gather-must-gather-commands.sh
cat >> ${WORKSPACE}/gather-must-gather-commands.sh << 'EOF'
#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export HOME=/tmp
export WORKSPACE=${WORKSPACE:-/tmp}
export PATH=${PATH}:${WORKSPACE}

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in calling must-gather."
	exit 0
fi

echo "Running must-gather..."
mkdir -p ${ARTIFACT_DIR}/must-gather
oc --insecure-skip-tls-verify adm must-gather --dest-dir ${ARTIFACT_DIR}/must-gather > ${ARTIFACT_DIR}/must-gather/must-gather.log
tar -czC "${ARTIFACT_DIR}/must-gather" -f "${ARTIFACT_DIR}/must-gather.tar.gz" .
rm -rf "${ARTIFACT_DIR}"/must-gather

EOF

run_rsync() {
  set -x
  rsync -PazcOq -e "ssh -o StrictHostKeyChecking=false -o UserKnownHostsFile=/dev/null -i ${SSH_PRIV_KEY_PATH}" "${@}"
  set +x
}

run_ssh() {
  set -x
  ssh -q -o StrictHostKeyChecking=false -o UserKnownHostsFile=/dev/null -i "${SSH_PRIV_KEY_PATH}" "${@}"
  set +x
}


REMOTE=$(<"${SHARED_DIR}/jump-host.txt") && export REMOTE
REMOTE_DIR="/tmp/install-$(date +%s%N)" && export REMOTE_DIR

if ! whoami &> /dev/null; then
  if [ -w /etc/passwd ]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
  fi
fi

run_ssh "${REMOTE}" -- mkdir -p "${REMOTE_DIR}/cluster_profile" "${REMOTE_DIR}/shared_dir" "${REMOTE_DIR}/artifacts_dir"
cat >> ${WORKSPACE}/runner.env << EOF
export RELEASE_IMAGE_LATEST="${RELEASE_IMAGE_LATEST}"

export CLUSTER_TYPE="${CLUSTER_TYPE}"
export CLUSTER_PROFILE_DIR="${REMOTE_DIR}/cluster_profile"
export ARTIFACT_DIR="${REMOTE_DIR}/artifacts_dir"
export SHARED_DIR="${REMOTE_DIR}/shared_dir"
export KUBECONFIG="${REMOTE_DIR}/shared_dir/kubeconfig"

export JOB_NAME="${JOB_NAME}"
export BUILD_ID="${BUILD_ID}"

export WORKSPACE=${REMOTE_DIR}
EOF

run_rsync "$(which oc)" ${WORKSPACE}/runner.env ${WORKSPACE}/gather-must-gather-commands.sh "${REMOTE}:${REMOTE_DIR}/"
run_rsync "${SHARED_DIR}/" "${REMOTE}:${REMOTE_DIR}/shared_dir/"
run_rsync "${CLUSTER_PROFILE_DIR}/" "${REMOTE}:${REMOTE_DIR}/cluster_profile/"

run_ssh "${REMOTE}" "source ${REMOTE_DIR}/runner.env && bash ${REMOTE_DIR}/gather-must-gather-commands.sh" &

set +e
wait "$!"
ret="$?"
set -e

run_rsync "${REMOTE}:${REMOTE_DIR}/shared_dir/" "${SHARED_DIR}/"
run_rsync --no-perms "${REMOTE}:${REMOTE_DIR}/artifacts_dir/" "${ARTIFACT_DIR}/"
run_ssh "${REMOTE}" "rm -rf ${REMOTE_DIR}"
exit "$ret"
