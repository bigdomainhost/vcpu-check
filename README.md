# vcpu-check

**About:** A single bash script that shows what CPU your Linux VM really has (generic virtual model or host model, AVX2/AES flags) and measures CPU steal time, without root.

When you buy a VPS, the plan says "4 vCPU". It does not say what kind of CPU the guest sees, which instruction sets you get, or how often your vCPUs sit waiting while the physical core runs someone else's work. `vcpu-check.sh` answers those three questions from inside the machine in about ten seconds.

## What it checks

| Check | Where it comes from |
|---|---|
| Virtualization type (kvm, vmware, microsoft, xen, lxc, openvz, none...) | `systemd-detect-virt` if installed, otherwise the `hypervisor` flag in `/proc/cpuinfo`, DMI strings in `/sys/class/dmi/id/` and common container markers |
| CPU model string | `/proc/cpuinfo` (falls back to `lscpu`) |
| Generic virtual model or host model | Pattern match on the model string, for example `QEMU Virtual CPU` or `Common KVM processor` (generic), `Intel Xeon Processor (Icelake)` (named model for a CPU generation) or `Intel(R) Xeon(R) Gold ...` (host model passed through) |
| Key instruction-set flags | `avx2`, `avx512f`, `aes`, `sha_ni` in `/proc/cpuinfo` (x86 only) |
| vCPU count | Processors in `/proc/cpuinfo`, plus `nproc` (what this process may use) |
| CPU steal time | Two snapshots of `/proc/stat`, N seconds apart: steal as a share of total CPU time, for the whole machine and for the worst vCPU |

It then prints a short plain-English reading of the results.

## Requirements

- Linux with bash. Written for minimal Debian, Ubuntu and AlmaLinux/RHEL-family installs. On anything else (macOS, BSD, Git Bash or Cygwin on Windows) it exits with a message instead of printing misleading numbers.
- Only standard base tools: `awk` (mawk or gawk), `grep`, `sed`, `tr`, `fold`, `sleep`, `nproc`, `uname`. Nothing to install, no root needed. (Not tested on BusyBox-only systems.)
- Works inside VMs, on bare metal and inside containers (with the caveats below).

## Quick start

```bash
curl -fsSLO https://raw.githubusercontent.com/bigdomainhost/vcpu-check/main/vcpu-check.sh
less vcpu-check.sh          # read it first; it is one short file
bash vcpu-check.sh --load
```

Or clone the repo and run `bash vcpu-check.sh`.

## Options

```
-s, --seconds N   sample steal time for N seconds (default 10, max 3600)
-l, --load        keep every vCPU busy while sampling (recommended)
-j, --json        print JSON instead of the text report
-V, --version     print the version
-h, --help        show help
```

`--load` starts one busy loop per usable vCPU, waits one second for them to get scheduled, samples for the chosen length and stops them when the script exits (including on Ctrl+C). It uses nothing but CPU time.

## Example output

The numbers below are illustrative, not a measurement of any provider. The layout and wording are exactly what the script prints (the "Sampling..." progress line goes to stderr and is left out).

```
vcpu-check 1.0.0

Virtualization
  Type               kvm (virtual machine, via systemd-detect-virt)
  Hypervisor flag    yes
  DMI                QEMU / Standard PC (i440FX + PIIX, 1996)

CPU
  Model              QEMU Virtual CPU version 2.5+
  Model type         generic virtual model
  vCPUs              4 (4 usable by this process)
  avx2               no
  avx512f            no
  aes                no
  sha_ni             no

Steal time (10 s, all vCPUs busy)
  Average steal      5.90 %  [high]
  Highest vCPU       cpu2 at 7.44 %
  Machine busy       92.26 %

What this means
  - This is a virtual machine (hypervisor: kvm). Your vCPUs are scheduled by
    a hypervisor on a physical host.
  - The CPU model "QEMU Virtual CPU version 2.5+" is a generic virtual model.
    The hypervisor hides the real host CPU and exposes a reduced, portable
    instruction set, which makes it easy to move the VM between different
    hosts. Software that looks for AVX2, AES-NI or SHA extensions may run
    slower or refuse to start.
  - Not exposed to this machine: avx2 avx512f aes sha_ni. avx512f is missing
    on many CPUs, including most AMD chips before Zen 4, so that alone is
    normal. A missing avx2 or aes on a modern server usually means the
    hypervisor is masking them.
  - High steal (5.90%). A large share of the CPU time your vCPUs wanted went
    to other work on the host. Steady steal at this level suggests a busy
    shared host. Reserved cores on a VDS or dedicated server should show
    close to 0%.
```

With `--json` you get the same data as one object (`virtualization`, `cpu`, `steal`, `interpretation`), which is handy for running it from cron and graphing steal over a day. When steal cannot be measured, the steal numbers are `null` and `level` is `"unavailable"`.

## How to read the results

### Steal time

Steal is time when your vCPU was ready to run but the hypervisor gave the physical CPU to something else. The script grades the average:

| Average steal | Label | What it usually means |
|---|---|---|
| under 0.5 % | none | You got the CPU time you asked for during the sample. |
| 0.5 to 2 % | low | Normal for shared (fair-share) vCPUs on a moderately busy host. Most workloads will not notice. |
| 2 to 5 % | moderate | Noticeable. If it is steady across several runs, you are on contended fair-share vCPUs. Game servers, real-time APIs and builds feel this. |
| 5 % and up | high | A busy shared host. Expect uneven latency. |

A single run is a snapshot. Run it with `--load` a few times across the day, especially at your peak hours, before concluding anything.

### CPU model and flags

- **Generic virtual model** (`QEMU Virtual CPU`, `Common KVM processor`): the hypervisor hides the host CPU and offers a small, portable instruction set so the VM can move between different hosts easily. Software that expects AVX2, AES-NI or SHA extensions (some databases, video encoders, ML libraries, crypto-heavy services) may run slower or refuse to start.
- **Named virtual model** (`Intel Xeon Processor (Icelake)`, `AMD EPYC-Rome Processor`): a model for a CPU generation. The flags match that generation, usually close to the host.
- **Host model** (`Intel(R) Xeon(R) ...`, `AMD EPYC 7xx3 ...`): the real host CPU is passed through with its full instruction set. This tells you about features, not about sharing. Steal time is the sharing signal.

### Fair-share vCPU vs reserved cores

Most VPS plans use fair-share vCPUs: each vCPU is a thread the hypervisor schedules onto physical cores shared by several tenants. You usually get burst headroom when neighbours are quiet, and some steal when they are not. That is a fine trade for websites, small apps and dev boxes.

On a VDS or a dedicated server, whole physical cores are reserved for you, so steal should stay close to 0 % even under `--load`. Reserved cores do not make everything private, though. On a VDS the L3 cache, memory bandwidth, disk and network are still shared with other tenants on the host, and `vcpu-check` does not measure those.

## Honest caveats

- **Zero steal is not proof of reserved cores.** A fair-share VPS on a quiet host can show 0 % for hours. High steal is strong evidence of contention; low steal is weak evidence of the opposite.
- **An idle machine shows little steal.** Steal only builds up while your vCPUs want to run. Without `--load` the script warns you when the machine was mostly idle.
- **Not every hypervisor reports steal.** KVM and Xen guests normally do. Some VMware and Hyper-V setups do not report it to Linux guests, so 0 % there means little.
- **Containers are different.** In LXC, OpenVZ or Docker the CPU model and flags are the host's, limits come from cgroups, and steal is often zero or a host-wide figure.
- **Shared hosting accounts (CloudLinux LVE) are not VMs.** On a cPanel-style shared host the script reports the server underneath (often bare metal) and adds a `CloudLinux LVE` line. Your account's CPU is capped per user by LVE, and that throttling never shows up as steal.
- **The model check is a pattern match.** Providers can rename CPU models. The script reports the raw string so you can judge it yourself.
- **It does not benchmark.** It does not measure single-core speed, cache, memory bandwidth, disk or network.
- **`--load` uses real CPU.** It is ten seconds of busy loops by default. Do not run it on a production box at a critical moment.

## Contributing

Issues and pull requests are welcome, especially new CPU model strings, hypervisor quirks and output from distributions not listed above. Please keep the script dependency-free and shellcheck-clean (`shellcheck vcpu-check.sh`).

## Licence

MIT. See [LICENSE](LICENSE).

## Made by Bigdomainhost

Disclosure: this tool is written and maintained by the Bigdomainhost team. We sell both fair-share VPS and VDS plans with reserved cores, which is why we wanted a neutral way to check the difference from inside any server, ours or anyone else's. The script does not contact us or anyone else.

Made by Bigdomainhost — we explain VPS vs VDS here: https://bigdomainhost.com/vds-hosting.html
