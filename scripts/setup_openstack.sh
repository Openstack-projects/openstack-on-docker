#!/bin/bash
#
# Copyright (c) 2015 Davide Guerri <davide.guerri@gmail.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -uexo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

CIDR="10.29.29.0/24"
GATEWAY="10.29.29.1"
START_IP="10.29.29.20"
END_IP="10.29.29.200"
DNS="10.29.29.1"

NODE_CPUS=1
NODE_RAM=1024
NODE_DISK=8
NODE_ARCH=x86_64

download_if_not_exist() {
    local url="$1"
    local filename=$(basename $1)

    if [ ! -f "$SCRIPT_DIR/$filename" ]; then
        curl -s -o "$SCRIPT_DIR/$filename" "$url"
    fi
}

# -- [ Neutron
neutron net-create \
    --shared \
    --router:external \
    --provider:network_type flat \
    --provider:physical_network external \
    external

neutron subnet-create \
    --name external \
    --gateway "$GATEWAY"\
    --allocation-pool "start=$START_IP,end=$END_IP" \
    --enable-dhcp \
    --dns-nameserver "$DNS" \
    external \
    "$CIDR"

# -- [ Glance
download_if_not_exist \
    http://download.cirros-cloud.net/0.3.4/cirros-0.3.4-x86_64-disk.img
download_if_not_exist \
    http://tarballs.openstack.org/ironic-python-agent/coreos/files/coreos_production_pxe.vmlinuz
download_if_not_exist \
    http://tarballs.openstack.org/ironic-python-agent/coreos/files/coreos_production_pxe_image-oem.cpio.gz

glance image-create \
    --name="Cirros 0.3.4 - x86_64" \
    --is-public=true \
    --container-format=bare \
    --disk-format=qcow2 \
    --progress \
    --file "$SCRIPT_DIR/cirros-0.3.4-x86_64-disk.img"

glance image-create \
    --name "IPA deploy kernel - x86_64" \
    --is-public True \
    --disk-format aki \
    --progress \
    --file "$SCRIPT_DIR/coreos_production_pxe.vmlinuz"

kernel_id="$(glance image-list | awk '/IPA deploy kernel - x86_64/ {print $2}')"

glance image-create \
    --name "IPA deploy initrd - x86_64" \
    --is-public True \
    --disk-format ari \
    --progress \
    --file "$SCRIPT_DIR/coreos_production_pxe_image-oem.cpio.gz"

initrd_id="$(glance image-list | awk '/IPA deploy initrd - x86_64/ {print $2}')"

# -- [ Nova flavor
nova flavor-create ParallelsVM auto "$NODE_RAM" "$NODE_DISK" "$NODE_CPUS"
nova flavor-key ParallelsVM set cpu_arch="$NODE_ARCH"
nova flavor-key ParallelsVM set capabilities:boot_option="local"

# -- [ Ironic
ironic node-create \
    --driver agent_ssh \
    --name "ironic-bm1" \
    --driver-info deploy_kernel="$kernel_id" \
    --driver-info deploy_ramdisk="$initrd_id" \
    --driver-info ssh_username="davide" \
    --driver-info ssh_key_contents="$(cat ~/.ssh/id_rsa)" \
    --driver-info ssh_virt_type="parallels" \
    --driver-info ssh_address="10.211.55.2" \
    --properties capabilities="boot_option:local" \
    --properties memory_mb="$NODE_RAM" \
    --properties cpu_arch="$NODE_ARCH" \
    --properties local_gb="$NODE_DISK" \
    --properties cpus="$NODE_CPUS"

ironic node-update "ironic-bm1" add \
    instance_info/capabilities='{"boot_option": "local"}'

node_uuid="$(ironic node-list | awk '/ironic-bm1/ {print $2}')"

ironic port-create \
    --node "$node_uuid" \
    --address 00:1C:42:89:64:34