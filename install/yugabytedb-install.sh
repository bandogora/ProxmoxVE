#!/usr/bin/env bash

# Copyright (c) 2021-2025 bandogora
# Author: bandogora
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://www.yugabyte.com/yugabytedb/

# Import Functions und Setup
source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# Installing Dependencies with the 3 core dependencies (curl;sudo;mc)
msg_info "Installing Dependencies"
set -ex
$STD dnf install --disableplugin=subscription-manager -y \
  curl \
  sudo \
  mc \
  file \
  jq \
  bind-utils \
  diffutils \
  gettext \
  glibc-all-langpacks \
  glibc-langpack-en \
  glibc-locale-source \
  iotop \
  less \
  ncurses-devel \
  net-tools \
  openssl \
  openssl-devel \
  redhat-rpm-config \
  rsync \
  procps \
  python3.11-devel \
  python3.11-pip \
  sysstat \
  tcpdump \
  which \
  strip
msg_ok "Installed Dependencies"

msg_info "Setting ENV variables"
YB_SERIES=v2025.2
YB_HOME=/home/yugabyte
YB_MANAGED_DEVOPS_USE_PYTHON3=1
YB_DEVOPS_USE_PYTHON3=1
BOTO_PATH=/home/yugabyte/.boto/config
AZCOPY_JOB_PLAN_LOCATION=/tmp/azcopy/jobs-plan
AZCOPY_LOG_LOCATION=/tmp/azcopy/logs
DATA_DIR=/mnt/disk0

keys=(
YB_SERIES
YB_HOME
YB_MANAGED_DEVOPS_USE_PYTHON3
YB_DEVOPS_USE_PYTHON3
BOTO_PATH
AZCOPY_JOB_PLAN_LOCATION
AZCOPY_LOG_LOCATION
)
for k in "${keys[@]}"; do
val=$(printf '%s' "${!k}" | sed 's/"/\"/g')
sudo sh -c "printf '%s\n' ${k}=${val} >> /etc/environment"
done
msg_ok "Set ENV variables"

msg_info "Installing Python3 Dependencies"
alternatives --install /usr/bin/python python /usr/bin/python3.11 99
alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 99
$STD python3 -m pip install --upgrade pip
$STD python3 -m pip install --upgrade lxml
$STD python3 -m pip install --upgrade s3cmd
$STD python3 -m pip install --upgrade psutil
msg_ok "Installed Python3 Dependencies"

msg_info "Creating yugabyte user"
useradd --home-dir $YB_HOME \
        --uid 10001 \
        --shell /sbin/nologin \
        --no-create-home \
        --no-user-group yugabyte
msg_ok "Created yugabyte user"

# Setup App
msg_info "Setup ${APPLICATION}"

# Create YB_HOME and set as working dir
mkdir $YB_HOME && cd $YB_HOME || exit

# Get latest version and build number for our series
read -r VERSION RELEASE < <( \
  curl -fsSL https://github.com/yugabyte/yugabyte-db/raw/refs/heads/master/docs/data/currentVersions.json | \
  jq -r ".dbVersions[] | select(.series == \"${YB_SERIES}\") | [.version, .appVersion] | @tsv" \
)
curl -fsSL "https://software.yugabyte.com/releases/${VERSION}/yugabyte-${RELEASE}-linux-$(uname -m).tar.gz"

tar -xvf "/tmp/yugabyte*$(uname -m)*.tar.gz" --strip 1
rm -rf /tmp/yuabyte*
# Run post install
./bin/post_install.sh
tar -xvf share/ybc-*.tar.gz
rm -rf ybc-*/conf/

for a in $(find . -exec file {} \; | grep -i elf | cut -f1 -d:); do
  strip --strip-unneeded "$a" || true
done

languages=("en_US" "de_DE" "es_ES" "fr_FR" "it_IT" "ja_JP"
          "ko_KR" "pl_PL" "ru_RU" "sv_SE" "tr_TR" "zh_CN");
for lang in "${languages[@]}"; do
  localedef --quiet --force --inputfile="${lang}" --charmap=UTF-8 "${lang}.UTF-8";
done

for a in ysqlsh ycqlsh yugabyted yb-admin yb-tsi-cli; do
  ln -s $YB_HOME/bin/$a /usr/local/bin/$a;
done

shopt -s extglob
mkdir $YB_HOME/{master,tserver}
# Link all YB pieces.
for dir in !(^ybc-*); do ln -s $YB_HOME/"$dir" $YB_HOME/master/"$dir"; done
for dir in !(^ybc-*); do ln -s $YB_HOME/"$dir" $YB_HOME/tserver/"$dir"; done
# Link the logs.
ln -s $DATA_DIR/yb-data/master/logs $YB_HOME/master/logs
ln -s $DATA_DIR/yb-data/tserver/logs $YB_HOME/tserver/logs

mkdir $YB_HOME/controller
# Find ybc-* directory
YBC_DIR=$(find "$YB_HOME" -maxdepth 1 -type d -name 'ybc-*');
# Link bin directory
ln -s "${YBC_DIR}"/bin $YB_HOME/controller/bin
# Link the logs
ln -s $DATA_DIR/ybc-data/controller/logs $YB_HOME/controller/logs

ghr_url=https://raw.githubusercontent.com/yugabyte/yugabyte-db/master
mkdir /licenses
curl ${ghr_url}/LICENSE.md -o /licenses/LICENSE.md
curl ${ghr_url}/licenses/APACHE-LICENSE-2.0.txt -o /licenses/APACHE-LICENSE-2.0.txt
curl ${ghr_url}/licenses/POLYFORM-FREE-TRIAL-LICENSE-1.0.0.txt \
  -o /licenses/POLYFORM-FREE-TRIAL-LICENSE-1.0.0.txt

# Install azcopy
msg_info "Installing azcopy"
curl -fsSL -O https://packages.microsoft.com/keys/microsoft.asc
rpm --import microsoft.asc
curl -fsSL -O https://packages.microsoft.com/config/alma/9/packages-microsoft-prod.rpm
rpm --quiet -K packages-microsoft-prod.rpm
dnf -q update
dnf -q install azcopy
rm -f microsoft.asc packages-microsoft-prod.rpm
mkdir -m 777 /tmp/azcopy
msg_ok "Installed azcopy"

# Install gsutil
msg_info "Installing gsutil"
sudo tee -a /etc/yum.repos.d/google-cloud-sdk.repo << EOM
[google-cloud-cli]
name=Google Cloud CLI
baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el9-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOM
dnf -q update
dnf -yq install libxcrypt-compat.x86_64
dnf -yq install google-cloud-cli

# Configure azcopy and gsutil
mkdir $YB_HOME/.boto
echo -e "[GSUtil]\nstate_dir=/tmp/gsutil" > $YB_HOME/.boto/config
mkdir -m 777 /tmp/gsutil
msg_ok "Installed gsutil"

# Set correct ownership and permissions for yugabyte user
mkdir -m 777 /tmp/yb-port-locks
mkdir -m 777 /tmp/yb-controller-tmp
chown -R yugabyte $YB_HOME
chown -R yugabyte $DATA_DIR

mv "${APPLICATION}"-"${RELEASE}"/ /opt/"${APPLICATION}"
echo "${RELEASE}" >/opt/"${APPLICATION}"_version.txt
msg_ok "Setup ${APPLICATION}"

# Creating Service (if needed)
msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/"${APPLICATION}".service
[Unit]
Description=${APPLICATION} Service
Wants=network-online.target
After=network-online.target

[Service]
Type=forking
RestartForceExitStatus=SIGPIPE
StartLimitInterval=0
ExecStart=/bin/bash -c '/usr/local/bin/yugabyted start --secure \
--backup_daemon=true \
--fault_tolerance=zone \
--advertise_address=${} \
--tserver_flags="enable_ysql_conn_mgr=true,tmp_dir=/home/yugabyte/var/tmp,durable_wal_write=true" \
--data_dir=$DATA_DIR \
--callhome=false'


YB_DEVOPS_USE_PYTHON3=YB_DEVOPS_USE_PYTHON3
BOTO_PATH=BOTO_PATH
AZCOPY_JOB_PLAN_LOCATION=AZCOPY_JOB_PLAN_LOCATION
AZCOPY_LOG_LOCATION=AZCOPY_LOG_LOCATION
Environment="YB_HOME=$YB_HOME"
Environment="YB_MANAGED_DEVOPS_USE_PYTHON3=$YB_MANAGED_DEVOPS_USE_PYTHON3"
Environment="YB_DEVOPS_USE_PYTHON3=$YB_DEVOPS_USE_PYTHON3"
Environment="BOTO_PATH=$BOTO_PATH"
Environment="AZCOPY_JOB_PLAN_LOCATION=$AZCOPY_JOB_PLAN_LOCATION"
Environment="AZCOPY_LOG_LOCATION=$AZCOPY_LOG_LOCATION"
WorkingDirectory=/home/yugabyte/
TimeoutStartSec=30
LimitCORE=infinity
LimitNOFILE=1048576
LimitNPROC=12000
RestartSec=5
PermissionsStartOnly=True
User=yugabyte
TimeoutStopSec=300
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl enable -q --now "${APPLICATION}".service
msg_ok "Created Service"

motd_ssh
customize

# Cleanup
msg_info "Cleaning up"
rm -f "${RELEASE}".zip
rm -rf /usr/share/python3-wheels/pip-9.0.3-py2.py3-none-any.whl
rm -rf ~/.cache
$STD dnf clean all
rm -rf /var/cache/yum /var/cache/dnf
msg_ok "Cleaned"
