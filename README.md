# LDMS + VPIC: Memory Monitoring Verification

Setting up [LDMS](https://github.com/ovis-hpc/ovis) (a lightweight HPC
monitoring tool) to watch a real application's ([VPIC](https://github.com/lanl/vpic))
memory usage, first on one machine, then across two separate machines
in AWS.

## Table of Contents

- [Goal](#goal)
- [Instance Setup](#instance-setup)
- [Building LDMS and VPIC](#building-ldms-and-vpic)
- [Test 1: Local Memory-Bound Verification](#test-1-local-memory-bound-verification-no-networking)
- [Test 2: Two-Instance Networked Connection](#test-2-two-instance-networked-connection)
- [Results Summary](#results-summary)
- [Key Takeaways](#key-takeaways)

## Goal

Three questions:

1. Does LDMS correctly detect an application's memory usage?
2. Does that effect scale with a bigger workload?
3. Can two separate cloud computers talk to each other for this monitoring?

## Instance Setup

Only one instance was configured by hand through the AWS EC2 console,
**Instance A**. The second instance (the aggregator) was launched via a
single automated script command
(`NUM_SAMPLERS=0 ./launch_instances.sh`, from the
[`anaveroneze/ldms-cloud`](https://github.com/anaveroneze/ldms-cloud)
repo), which handled the AMI selection, security group creation, and IAM
permissions automatically in the background.

### Instance A: `ldms-vpic` (Sampler + VPIC host)

| Setting | Value |
|---|---|
| AMI | Ubuntu Server 24.04 LTS |
| Instance type | t2.medium / t3.medium (4 GiB RAM) |
| Storage | 20 GiB |
| Security group | `launch-wizard-83` (`sg-0fa482735fc150d48`) |
| Private IP | `172.31.18.232` |

> **Note:** `t3.micro` (1 GiB RAM) was tried first and was too small to
> build LDMS from source — upgraded to `t2/t3.medium`.

### Instance B: `aggregator` (launched via `ldms-cloud` automation)

| Setting | Value |
|---|---|
| AMI | Ubuntu 22.04 (jammy) |
| Launched via | `anaveroneze/ldms-cloud` repo's `launch_instances.sh` |
| Security group | `cluster-sg` (`sg-0638d5c6b0af5ea1a`) |
| Private IP | `172.31.55.134` |
| IAM role | `ldms-cluster-profile` (auto-created by the launch script) |

## Building LDMS and VPIC

### Install Dependencies

```bash
sudo apt-get update -y
sudo apt-get install -y \
  autoconf automake libtool pkg-config make \
  bison flex libssl-dev bzip2 \
  hdf5-tools libhdf5-openmpi-dev openmpi-bin \
  python3-dev python-dev-is-python3 python3-docutils \
  libjansson-dev git cmake g++ unzip
```

> **Note:** On Ubuntu 24.04, `python3.10` is not available in the default
> repos (24.04 ships Python 3.12) — the system Python was used instead.

### Build LDMS (OVIS)

```bash
cd ~
git clone https://github.com/ovis-hpc/ovis.git
cd ovis && mkdir build
./autogen.sh && cd build
../configure --prefix=${HOME}/ovis/build
make
make install
```

### LDMS Environment Script

```bash
cat > ~/set-ldms-env.sh << 'EOF'
#!/bin/sh
export LDMS_INSTALL_PATH=/home/ubuntu/ovis/build
export LD_LIBRARY_PATH=$LDMS_INSTALL_PATH/lib/:$LD_LIBRARY_PATH
export LDMSD_PLUGIN_LIBPATH=$LDMS_INSTALL_PATH/lib/ovis-ldms
export ZAP_LIBPATH=$LDMS_INSTALL_PATH/lib/ovis-ldms
export PATH=$LDMS_INSTALL_PATH/sbin:$LDMS_INSTALL_PATH/bin:$PATH
export COMPONENT_ID="1"
export SAMPLE_INTERVAL="1000000"
export SAMPLE_OFFSET="0"
export HOSTNAME="localhost"
EOF

source ~/set-ldms-env.sh
which ldmsd
# Confirmed: /home/ubuntu/ovis/build/sbin/ldmsd
```

### Build VPIC

```bash
cd ~
git clone https://github.com/lanl/vpic.git
cd vpic
mkdir build && cd build
../arch/reference-Release
make
```

> **Note:** `make` only builds VPIC's compiler wrapper (`bin/vpic`), not
> the actual simulation binary. The simulation deck must be compiled
> separately.

### Compile the `harris` Simulation Deck

```bash
./bin/vpic ../sample/harris
ls -la harris.Linux
# Confirmed: harris.Linux built successfully
```

## Test 1: Local Memory-Bound Verification (No Networking)

**Purpose:** confirm LDMS detects VPIC's memory usage on one computer
only, before introducing any networking complexity.

### Local-Only LDMS Config

```bash
cat > ~/meminfo-local.conf << 'EOF'
load name=meminfo
config name=meminfo producer=${HOSTNAME} instance=${HOSTNAME}/meminfo component_id=1
start name=meminfo interval=1s
EOF
```

### Start Local `ldmsd`

```bash
source ~/set-ldms-env.sh
pkill ldmsd 2>/dev/null
sleep 2
ldmsd -x sock:10444 -c ~/meminfo-local.conf -l /tmp/meminfo-local.log -v INFO &
sleep 3
ldms_ls -x sock -p 10444 -h localhost -v
# Confirmed: one set, localhost/meminfo
```

### Polling Script (records memory every second)

```bash
cat > ~/poll_meminfo.sh << 'EOF'
#!/bin/bash
OUT=~/meminfo_timeseries.txt
> $OUT
while true; do
  echo "=== $(date +%s) ===" >> $OUT
  ldms_ls -x sock -p 10444 -h localhost -l -v localhost/meminfo >> $OUT 2>&1
  sleep 1
done
EOF
chmod +x ~/poll_meminfo.sh
```

### Run 1: Default VPIC Problem Size

```bash
nohup ~/poll_meminfo.sh > /dev/null 2>&1 &
sleep 1
cd ~/vpic/build
mpirun -n 1 ./harris.Linux --tpp 8
pkill -f poll_meminfo.sh
grep -E "MemFree|MemAvailable|===" ~/meminfo_timeseries.txt
```

**Result:**

| Phase | MemFree (KB) |
|---|---|
| Before VPIC | ~913,800 |
| During VPIC | ~878,000–884,600 |
| After VPIC | ~898,000+ (recovering) |

Drop of **~30–34 MB**. Runtime: ~13 seconds, 484 simulation steps. Real
signal, but modest.

### Run 2: Scaled-Up Problem Size (Stronger Signal)

Doubled the simulation grid resolution to force a bigger memory
footprint:

```bash
cp ~/vpic/sample/harris ~/vpic/sample/harris.bak
sed -i 's/double nx        = 64;/double nx        = 128;/' ~/vpic/sample/harris
sed -i 's/double ny        = 64;/double ny        = 128;/' ~/vpic/sample/harris

cd ~/vpic/build
./bin/vpic ../sample/harris     # recompile the deck with new grid size
```

```bash
cat > ~/poll_meminfo.sh << 'EOF'
#!/bin/bash
OUT=~/meminfo_timeseries_v2.txt
> $OUT
while true; do
  echo "=== $(date +%s) ===" >> $OUT
  ldms_ls -x sock -p 10444 -h localhost -l -v localhost/meminfo >> $OUT 2>&1
  sleep 1
done
EOF
chmod +x ~/poll_meminfo.sh

nohup ~/poll_meminfo.sh > /dev/null 2>&1 &
sleep 1
mpirun -n 1 ./harris.Linux --tpp 8
pkill -f poll_meminfo.sh
grep -E "MemFree|MemAvailable|===" ~/meminfo_timeseries_v2.txt
```

**Result:**

| Phase | MemFree (KB) |
|---|---|
| Before VPIC | ~892,000 |
| Minimum during VPIC | ~148,728 |
| After VPIC | ~377,000+ (recovering) |

Drop of **~726 MB**, roughly 6x larger than Run 1, matching the 4x
bigger grid/particle count. Runtime scaled to ~80 seconds (~6x longer).

> **Conclusion:** LDMS clearly detects VPIC's memory usage, and the
> effect scales predictably with problem size.

## Test 2: Two-Instance Networked Connection

**Purpose:** get a sampler (Instance A) and an aggregator (Instance B)
running on separate cloud computers to talk to each other.

### Attempt 1: The "Advertiser" Method (Failed — Crash Bug)

LDMS's newer peer-discovery mechanism lets the sampler "advertise"
itself to the aggregator:

```bash
# On the sampler (Instance A):
cat > ~/samplerd-vpic.conf << 'EOF'
advertiser_add name=agg11 xprt=sock host=<AGGREGATOR_IP> port=10444 reconnect=10s
advertiser_start name=agg11

load name=meminfo
config name=meminfo producer=${HOSTNAME} instance=${HOSTNAME}/meminfo
start name=meminfo interval=1s
EOF

ldmsd -x sock:10444 -c ~/samplerd-vpic.conf -l /tmp/samplerd.log -v INFO -m 1g &
```

**Result:** crashed every time, with:

```
*** buffer overflow detected ***: terminated
```

This happened consistently, even with:

- A completely minimal config (just `meminfo`, no other plugins)
- A freshly rebuilt LDMS from the latest available code (`git pull` +
  rebuild — confirmed no newer commit existed, same result)
- Increased memory allocation (`-m 1g`)

> **Conclusion:** this is a genuine bug in LDMS's advertiser/peer-discovery
> code (`ldmsd_peer_daemon_advertisement`), not a configuration mistake.

### Attempt 2: The Older "Static" Method (Success)

Instead of the sampler advertising itself, the aggregator directly dials
the sampler using `prdcr_add`:

**On the sampler (Instance A)**: simplified, no advertiser at all:

```bash
cat > ~/samplerd-static.conf << 'EOF'
load name=meminfo
config name=meminfo producer=${HOSTNAME} instance=${HOSTNAME}/meminfo
start name=meminfo interval=1s
EOF

source ~/set-ldms-env.sh
ldmsd -x sock:10444 -c ~/samplerd-static.conf -l /tmp/samplerd-static.log -v INFO -m 1g &
```

**On the aggregator (Instance B)**: static producer config:

```bash
cat > ~/agg-static.conf << 'EOF'
prdcr_add name=vpic_sampler xprt=sock host=172.31.18.232 port=10444 type=active reconnect=10s
prdcr_start name=vpic_sampler

updtr_add name=all_sets interval=1s offset=100ms
updtr_prdcr_add name=all_sets regex=.*
updtr_start name=all_sets
EOF

source ~/set-ldms-env.sh
ldmsd -x sock:10444 -c ~/agg-static.conf -l /tmp/agg-static.log -v INFO -m 1g &
```

### Networking Roadblock (Firewall, Not a Bug)

Initial connection attempts failed with `connection error`. Root cause:
AWS security groups (cloud firewall rules) weren't open between the two
instances' actual IPs. Fixed with:

```bash
# Allow the aggregator to reach the sampler:
aws ec2 authorize-security-group-ingress \
  --group-id sg-0fa482735fc150d48 \
  --protocol tcp --port 10444 \
  --cidr 172.31.55.134/32   # aggregator's IP

# Allow the sampler to reach the aggregator:
aws ec2 authorize-security-group-ingress \
  --group-id sg-0638d5c6b0af5ea1a \
  --protocol tcp --port 10444 \
  --cidr 172.31.18.232/32   # sampler's IP
```

### Final Verification: It Worked

After the firewall fix, restarted the aggregator and checked directly:

```bash
ldms_ls -x sock -p 10444 -h localhost -v
```

**Result:**

```
Schema    Instance              Flags  ...
meminfo   localhost/meminfo     CR     ...
Total Sets: 1
```

`CR` = **C**ached, **R**emote: confirming the aggregator successfully
pulled the metric set from the sampler across the network, on two
separate real EC2 instances, with **no crash**.

## Results Summary

| Question | Result |
|---|---|
| Does LDMS detect an app's real memory usage? | Yes, confirmed locally with VPIC |
| Does the effect scale with workload size? | Yes, 4x bigger problem → ~6x bigger memory drop |
| Can two separate cloud computers connect for monitoring? | Yes, using the `prdcr_add` static method |
| Does the newer "advertiser" method work? | No, confirmed crash bug |

## Key Takeaways

- The core monitoring pipeline works end-to-end, app runs, LDMS
  detects the memory impact, data is collectible.
- **Avoid LDMS's `advertiser` feature for now** — it has a real,
  reproducible crash bug in the current build. Use the older `prdcr_add`
  method instead, which is fully proven working.
- Most "failures" along the way were infrastructure issues (AMI/OS
  mismatches, missing dependencies, firewall rules) rather than problems
  with LDMS or VPIC themselves, worth remembering for future setups on
  fresh instances.
