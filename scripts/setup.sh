#!/bin/bash
# One-shot setup: installs dependencies and builds LDMS (OVIS) from
# source. Tested on Ubuntu 24.04 LTS. Run this on a fresh instance
# before using the configs in ../configs/.

set -e

sudo apt-get update -y
sudo apt-get install -y \
  autoconf automake libtool pkg-config make \
  bison flex libssl-dev bzip2 \
  hdf5-tools libhdf5-openmpi-dev openmpi-bin \
  python3-dev python-dev-is-python3 python3-docutils \
  libjansson-dev git cmake g++ unzip

cd ~
git clone https://github.com/ovis-hpc/ovis.git
cd ovis && mkdir -p build
./autogen.sh && cd build
../configure --prefix="${HOME}/ovis/build"
make
make install

echo "LDMS build complete. Now copy scripts/set-ldms-env.sh to ~/ and run:"
echo "  source ~/set-ldms-env.sh && which ldmsd"
