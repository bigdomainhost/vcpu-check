#!/usr/bin/env bash
# vcpu-check.sh - what kind of CPU does this Linux VM or server really have,
# and are its vCPUs waiting on the hypervisor?
#
# Reports: virtualization type, CPU model (generic virtual model or host
# model), key instruction-set flags, vCPU count and CPU steal time measured
# from /proc/stat over a sampling window. Needs no root and no extra packages.
#
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Bigdomainhost
# https://github.com/bigdomainhost/vcpu-check

set -u
export LC_ALL=C

VERSION="1.0.0"
SAMPLE_SECS=10
OUTPUT_JSON=0
LOAD=0
LOAD_PIDS=""
CHECK_FLAGS="avx2 avx512f aes sha_ni"

usage() {
	cat <<'EOF'
Usage: vcpu-check.sh [-s SECONDS] [-l] [--json]

Shows the virtualization type, CPU model, key CPU flags, vCPU count and
CPU steal time for this machine. Runs as a normal user.

Options:
  -s, --seconds N   sample steal time for N seconds (default 10, max 3600)
  -l, --load        keep every vCPU busy while sampling, so steal reflects
                    what you get when you actually ask for CPU (recommended)
  -j, --json        print JSON instead of the text report
  -V, --version     print the version and exit
  -h, --help        show this help and exit
EOF
}

die() {
	printf 'vcpu-check: %s\n' "$1" >&2
	exit 2
}

# Read the first line of a file, or print nothing if it is missing/unreadable.
read_first_line() {
	local line=""
	if [ -r "$1" ]; then
		IFS= read -r line <"$1" || true
	fi
	printf '%s' "$line"
}

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
		-s | --seconds)
			[ $# -ge 2 ] || die "missing value for $1"
			SAMPLE_SECS=$2
			shift 2
			;;
		--seconds=*)
			SAMPLE_SECS=${1#*=}
			shift
			;;
		-s[0-9]*)
			SAMPLE_SECS=${1#-s}
			shift
			;;
		-l | --load)
			LOAD=1
			shift
			;;
		-j | --json)
			OUTPUT_JSON=1
			shift
			;;
		-V | --version)
			printf 'vcpu-check %s\n' "$VERSION"
			exit 0
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			die "unknown option: $1 (try --help)"
			;;
		esac
	done

	case "$SAMPLE_SECS" in
	'' | *[!0-9]*) die "-s needs a whole number of seconds, got '$SAMPLE_SECS'" ;;
	esac
	# Strip leading zeros so the value is not read as octal anywhere.
	SAMPLE_SECS=$((10#$SAMPLE_SECS))
	if [ "$SAMPLE_SECS" -lt 1 ] || [ "$SAMPLE_SECS" -gt 3600 ]; then
		die "-s must be between 1 and 3600 seconds"
	fi
}

detect_virt() {
	DMI_VENDOR=$(read_first_line /sys/class/dmi/id/sys_vendor)
	DMI_PRODUCT=$(read_first_line /sys/class/dmi/id/product_name)

	HYPERVISOR_FLAG=no
	if grep -q '^flags.* hypervisor' /proc/cpuinfo 2>/dev/null; then
		HYPERVISOR_FLAG=yes
	fi

	VIRT=""
	VIRT_SOURCE=""
	if command -v systemd-detect-virt >/dev/null 2>&1; then
		# Prints "none" and exits 1 on bare metal; we only want the text.
		VIRT=$(systemd-detect-virt 2>/dev/null) || true
		[ -n "$VIRT" ] && VIRT_SOURCE="systemd-detect-virt"
	fi

	if [ -z "$VIRT" ]; then
		VIRT_SOURCE="cpuinfo/DMI heuristics"
		if [ -e /proc/user_beancounters ] || { [ -d /proc/vz ] && [ ! -d /proc/bc ]; }; then
			VIRT=openvz
		elif [ -e /.dockerenv ]; then
			VIRT=docker
		elif [ -e /run/.containerenv ]; then
			VIRT=podman
		else
			case "$DMI_VENDOR|$DMI_PRODUCT" in
			*QEMU* | *KVM* | *Bochs* | *OpenStack*) VIRT=kvm ;;
			*VMware*) VIRT=vmware ;;
			*innotek* | *VirtualBox*) VIRT=oracle ;;
			*Xen*) VIRT=xen ;;
			*Parallels*) VIRT=parallels ;;
			"Microsoft Corporation|Virtual Machine") VIRT=microsoft ;;
			*)
				if [ "$HYPERVISOR_FLAG" = yes ]; then
					VIRT=unknown-hypervisor
				else
					VIRT=none
				fi
				;;
			esac
		fi
	fi

	# CloudLinux shared hosting: each account runs inside an LVE, which caps
	# CPU per user with cgroups. That throttling never shows up as steal.
	LVE=no
	if [ -e /proc/lve ] || uname -r 2>/dev/null | grep -q 'lve' ||
		grep -qi cloudlinux /etc/os-release /etc/redhat-release 2>/dev/null; then
		LVE=yes
	fi

	case "$VIRT" in
	none) VIRT_KIND="bare-metal" ;;
	openvz | lxc | lxc-libvirt | systemd-nspawn | docker | podman | rkt | wsl | proot | pouch | container-other)
		VIRT_KIND="container"
		;;
	*) VIRT_KIND="vm" ;;
	esac
}

detect_cpu() {
	CPU_MODEL=$(awk '/^model name[ \t]*:/ { sub(/^[^:]*:[ \t]*/, ""); print; exit }' /proc/cpuinfo 2>/dev/null)
	if [ -z "$CPU_MODEL" ] && command -v lscpu >/dev/null 2>&1; then
		CPU_MODEL=$(lscpu 2>/dev/null | awk '/^Model name[ \t]*:/ { sub(/^[^:]*:[ \t]*/, ""); print; exit }')
	fi

	# QEMU/KVM can show the guest a generic model, a named model for a CPU
	# generation, or the real host model (host-passthrough).
	case "$CPU_MODEL" in
	"")
		MODEL_CLASS=unknown
		;;
	*"QEMU Virtual CPU"* | *"Common KVM processor"* | *"Common 32-bit KVM processor"* | *"QEMU TCG CPU"* | *"KVM Virtual"* | *"Virtual CPU"*)
		MODEL_CLASS=generic
		;;
	*"Processor ("*")"* | "AMD EPYC Processor"* | "AMD EPYC-"*" Processor"* | "Intel Xeon Processor"* | "Intel Core Processor"*)
		MODEL_CLASS=named-virtual
		;;
	*)
		MODEL_CLASS=host
		;;
	esac

	FLAGS_LINE=$(awk '/^(flags|Features)[ \t]*:/ { sub(/^[^:]*:[ \t]*/, ""); print; exit }' /proc/cpuinfo 2>/dev/null)
	IS_X86=no
	case "$(uname -m 2>/dev/null)" in
	x86_64 | i?86) IS_X86=yes ;;
	esac

	VCPUS=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null) || VCPUS=0
	NPROC=$(nproc 2>/dev/null) || NPROC=$VCPUS
	[ "$VCPUS" -gt 0 ] 2>/dev/null || VCPUS=$NPROC
}

has_flag() {
	case " $FLAGS_LINE " in
	*" $1 "*) printf 'yes' ;;
	*) printf 'no' ;;
	esac
}

start_load() {
	local i=0
	while [ "$i" -lt "$NPROC" ]; do
		while :; do :; done &
		LOAD_PIDS="$LOAD_PIDS $!"
		i=$((i + 1))
	done
}

stop_load() {
	local pid
	[ -n "$LOAD_PIDS" ] || return 0
	for pid in $LOAD_PIDS; do
		kill "$pid" 2>/dev/null
	done
	wait 2>/dev/null
	LOAD_PIDS=""
}

measure_steal() {
	local s0 s1 stats

	if [ "$OUTPUT_JSON" -eq 0 ]; then
		if [ "$LOAD" -eq 1 ]; then
			printf 'Sampling CPU steal for %s s with all %s vCPUs busy (plus 1 s to start the load)...\n' "$SAMPLE_SECS" "$NPROC" >&2
		else
			printf 'Sampling CPU steal for %s s...\n' "$SAMPLE_SECS" >&2
		fi
	fi

	if [ "$LOAD" -eq 1 ]; then
		start_load
		# Give the busy loops a moment to be scheduled before the first
		# snapshot, so the whole sample is taken under load.
		sleep 1
	fi
	s0=$(grep '^cpu' /proc/stat)
	sleep "$SAMPLE_SECS"
	s1=$(grep '^cpu' /proc/stat)
	stop_load

	# /proc/stat cpu lines: name user nice system idle iowait irq softirq steal guest guest_nice
	# guest time is already counted in user, so the total is fields 2..9.
	stats=$({
		printf '%s\n' "$s0"
		printf -- '--\n'
		printf '%s\n' "$s1"
	} | awk '
		$1 == "--" { phase = 1; next }
		{
			tot = 0
			for (f = 2; f <= 9 && f <= NF; f++) tot += $f
			st = (NF >= 9) ? $9 : 0
			idle = $5 + ((NF >= 6) ? $6 : 0)
			if (NF < 9) nosteal = 1
			if (phase == 0) { t0[$1] = tot; s0[$1] = st; i0[$1] = idle; next }
			if (!($1 in t0)) next
			dt = tot - t0[$1]; ds = st - s0[$1]; di = idle - i0[$1]
			if (dt <= 0) next
			sp = 100 * ds / dt
			bp = 100 * (dt - di - ds) / dt
			# Per-CPU iowait can go backwards on NO_HZ kernels, and some old
			# kernels had steal counters go backwards; keep the output sane.
			if (sp < 0) sp = 0
			if (sp > 100) sp = 100
			if (bp < 0) bp = 0
			if (bp > 100) bp = 100
			if ($1 == "cpu") { all_s = sp; all_b = bp; have = 1 }
			else if (sp > max_s || max_c == "") { max_s = sp; max_c = $1 }
		}
		END {
			if (!have || nosteal) { print "NA NA NA -"; exit }
			if (max_c == "") { max_c = "-"; max_s = all_s }
			printf "%.2f %.2f %.2f %s\n", all_s, all_b, max_s, max_c
		}')

	read -r STEAL_PCT BUSY_PCT MAX_STEAL_PCT MAX_STEAL_CPU <<EOF
$stats
EOF
	if [ -z "${STEAL_PCT:-}" ]; then
		STEAL_PCT=NA BUSY_PCT=NA MAX_STEAL_PCT=NA MAX_STEAL_CPU=-
	fi

	if [ "$STEAL_PCT" = NA ]; then
		STEAL_LEVEL=unavailable
	else
		STEAL_LEVEL=$(awk -v s="$STEAL_PCT" 'BEGIN {
			if (s < 0.5) print "none"
			else if (s < 2) print "low"
			else if (s < 5) print "moderate"
			else print "high"
		}')
	fi
}

# Build the plain-English interpretation, one finding per line.
interpret() {
	local missing="" f model_note=""
	INTERP=""

	add() { INTERP="${INTERP}$1
"; }

	case "$VIRT_KIND" in
	bare-metal)
		if [ "$LVE" = yes ]; then
			add "No hypervisor was detected, so the server itself looks like bare metal, but it runs CloudLinux LVE: this is most likely a shared hosting account. Your account's CPU is capped per user by LVE limits, which this tool does not see, and steal time does not apply to bare metal."
		else
			add "No hypervisor was detected, so this looks like bare metal (a dedicated server). All cores belong to this machine and steal time does not apply."
		fi
		;;
	container)
		add "This is a container ($VIRT), not a full virtual machine. The CPU model and flags you see are the host's, CPU limits come from cgroups rather than vCPUs, and steal time inside a container is often zero or the host-wide figure. Read the steal number with caution."
		;;
	*)
		add "This is a virtual machine (hypervisor: $VIRT). Your vCPUs are scheduled by a hypervisor on a physical host."
		if [ "$LVE" = yes ]; then
			add "It also runs CloudLinux LVE, so this is most likely a shared hosting account. Your account's CPU is capped per user by LVE limits, and that throttling does not show up as steal time."
		fi
		;;
	esac

	case "$MODEL_CLASS" in
	generic)
		model_note="The CPU model \"$CPU_MODEL\" is a generic virtual model. The hypervisor hides the real host CPU and exposes a reduced, portable instruction set, which makes it easy to move the VM between different hosts. Software that looks for AVX2, AES-NI or SHA extensions may run slower or refuse to start."
		;;
	named-virtual)
		model_note="The CPU model \"$CPU_MODEL\" is a hypervisor model named after a CPU generation, not the exact host CPU. The instruction set matches that generation, which is usually close to the host but can leave out newer extensions."
		;;
	host)
		if [ "$VIRT_KIND" = vm ]; then
			model_note="The CPU model \"$CPU_MODEL\" looks like a real host CPU, so the hypervisor passes the host model through and you get its instruction set. On its own this does not tell you whether your cores are shared or reserved; steal time is the better signal."
		fi
		;;
	unknown)
		model_note="The CPU model string could not be read."
		;;
	esac
	[ -n "$model_note" ] && add "$model_note"

	if [ "$IS_X86" = yes ]; then
		for f in $CHECK_FLAGS; do
			[ "$(has_flag "$f")" = no ] && missing="$missing $f"
		done
		if [ -n "$missing" ]; then
			add "Not exposed to this machine:${missing}. avx512f is missing on many CPUs, including most AMD chips before Zen 4, so that alone is normal. A missing avx2 or aes on a modern server usually means the hypervisor is masking them."
		else
			add "avx2, avx512f, aes and sha_ni are all exposed."
		fi
	else
		add "This is not an x86 CPU, so the x86 flag checks (avx2, avx512f, aes, sha_ni) do not apply."
	fi

	if [ "$VIRT_KIND" = bare-metal ]; then
		if [ "$STEAL_LEVEL" != unavailable ]; then
			add "Steal is ${STEAL_PCT}%, as expected with no hypervisor."
		fi
	else
	case "$STEAL_LEVEL" in
	unavailable)
		add "This kernel does not report steal time in /proc/stat, so contention could not be measured."
		;;
	none)
		add "Steal stayed at about zero (${STEAL_PCT}%): your vCPUs got the physical CPU time they asked for during the sample. That is what reserved cores (a VDS or dedicated server) should always look like. A fair-share VPS on a quiet host can look the same, so repeat the test at busy times of day before drawing conclusions."
		;;
	low)
		add "A little steal (${STEAL_PCT}%). This is normal for fair-share vCPUs on a moderately busy host, and most workloads will not notice it."
		;;
	moderate)
		add "Noticeable steal (${STEAL_PCT}%). For part of the sample your vCPUs were ready to run but the hypervisor was running someone else. If you see this steadily across several runs, you are on contended fair-share vCPUs; latency-sensitive work such as game servers, real-time APIs and builds will feel it."
		;;
	high)
		add "High steal (${STEAL_PCT}%). A large share of the CPU time your vCPUs wanted went to other work on the host. Steady steal at this level suggests a busy shared host. Reserved cores on a VDS or dedicated server should show close to 0%."
		;;
	esac

	if [ "$STEAL_LEVEL" != unavailable ] && [ "$MAX_STEAL_CPU" != "-" ]; then
		if awk -v m="$MAX_STEAL_PCT" -v a="$STEAL_PCT" 'BEGIN { exit !(m >= 5 && m >= 2 * a) }'; then
			add "One vCPU ($MAX_STEAL_CPU) saw ${MAX_STEAL_PCT}% steal, well above the average, so contention was uneven across your vCPUs."
		fi
	fi
	fi

	if [ "$VIRT_KIND" = vm ] && [ "$STEAL_LEVEL" = none ]; then
		case "$VIRT" in
		microsoft | vmware)
			add "Some $VIRT setups do not report steal time to Linux guests at all, so 0% here is weaker evidence than on KVM or Xen."
			;;
		esac
	fi

	if [ "$LOAD" -eq 0 ] && [ "$STEAL_LEVEL" != unavailable ] && [ "$VIRT_KIND" != bare-metal ]; then
		if awk -v b="$BUSY_PCT" 'BEGIN { exit !(b < 25) }'; then
			add "The machine was mostly idle during the sample (${BUSY_PCT}% busy). Steal only builds up while your vCPUs want to run, so run again with --load to see what you get under full load."
		fi
	fi
}

json_str() {
	local s=$1
	s=${s//\\/\\\\}
	s=${s//\"/\\\"}
	s=${s//$'\t'/\\t}
	s=${s//$'\r'/\\r}
	s=${s//$'\n'/\\n}
	# Drop any other control characters, which JSON does not allow raw.
	s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
	printf '"%s"' "$s"
}

json_bool() {
	if [ "$1" = yes ]; then printf 'true'; else printf 'false'; fi
}

json_num() {
	if [ "$1" = NA ] || [ -z "$1" ]; then printf 'null'; else printf '%s' "$1"; fi
}

print_json() {
	local f first=1 line
	printf '{\n'
	printf '  "tool": "vcpu-check",\n'
	printf '  "version": %s,\n' "$(json_str "$VERSION")"
	printf '  "virtualization": {\n'
	printf '    "type": %s,\n' "$(json_str "$VIRT")"
	printf '    "kind": %s,\n' "$(json_str "$VIRT_KIND")"
	printf '    "detected_by": %s,\n' "$(json_str "$VIRT_SOURCE")"
	printf '    "hypervisor_flag": %s,\n' "$(json_bool "$HYPERVISOR_FLAG")"
	printf '    "cloudlinux_lve": %s,\n' "$(json_bool "$LVE")"
	printf '    "dmi_vendor": %s,\n' "$(json_str "$DMI_VENDOR")"
	printf '    "dmi_product": %s\n' "$(json_str "$DMI_PRODUCT")"
	printf '  },\n'
	printf '  "cpu": {\n'
	printf '    "model": %s,\n' "$(json_str "$CPU_MODEL")"
	printf '    "model_class": %s,\n' "$(json_str "$MODEL_CLASS")"
	printf '    "arch_x86": %s,\n' "$(json_bool "$IS_X86")"
	printf '    "vcpus": %s,\n' "$VCPUS"
	printf '    "usable_vcpus": %s,\n' "$NPROC"
	printf '    "flags": {'
	for f in $CHECK_FLAGS; do
		[ "$first" -eq 1 ] || printf ','
		first=0
		printf ' %s: %s' "$(json_str "$f")" "$(json_bool "$(has_flag "$f")")"
	done
	printf ' }\n'
	printf '  },\n'
	printf '  "steal": {\n'
	printf '    "sample_seconds": %s,\n' "$SAMPLE_SECS"
	printf '    "with_load": %s,\n' "$([ "$LOAD" -eq 1 ] && printf true || printf false)"
	printf '    "percent": %s,\n' "$(json_num "$STEAL_PCT")"
	printf '    "max_vcpu_percent": %s,\n' "$(json_num "$MAX_STEAL_PCT")"
	printf '    "max_vcpu": %s,\n' "$(json_str "$MAX_STEAL_CPU")"
	printf '    "guest_busy_percent": %s,\n' "$(json_num "$BUSY_PCT")"
	printf '    "level": %s\n' "$(json_str "$STEAL_LEVEL")"
	printf '  },\n'
	printf '  "interpretation": ['
	first=1
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		[ "$first" -eq 1 ] || printf ','
		first=0
		printf '\n    %s' "$(json_str "$line")"
	done <<EOF
$INTERP
EOF
	printf '\n  ]\n'
	printf '}\n'
}

row() {
	printf '  %-18s %s\n' "$1" "$2"
}

print_text() {
	local f line label dmi="" mode
	printf '\nvcpu-check %s\n\n' "$VERSION"

	case "$VIRT_KIND" in
	bare-metal) label="no hypervisor detected" ;;
	container) label="container" ;;
	*) label="virtual machine" ;;
	esac
	printf 'Virtualization\n'
	row "Type" "$VIRT ($label, via $VIRT_SOURCE)"
	row "Hypervisor flag" "$HYPERVISOR_FLAG"
	[ "$LVE" = yes ] && row "CloudLinux LVE" "yes (shared hosting limits apply)"
	if [ -n "$DMI_VENDOR" ] || [ -n "$DMI_PRODUCT" ]; then
		dmi="$DMI_VENDOR / $DMI_PRODUCT"
	else
		dmi="not readable"
	fi
	row "DMI" "$dmi"

	printf '\nCPU\n'
	row "Model" "${CPU_MODEL:-unknown}"
	case "$MODEL_CLASS" in
	generic) row "Model type" "generic virtual model" ;;
	named-virtual) row "Model type" "named virtual model (CPU generation)" ;;
	host) row "Model type" "host CPU model" ;;
	*) row "Model type" "unknown" ;;
	esac
	row "vCPUs" "$VCPUS ($NPROC usable by this process)"
	if [ "$IS_X86" = yes ]; then
		for f in $CHECK_FLAGS; do
			row "$f" "$(has_flag "$f")"
		done
	fi

	if [ "$LOAD" -eq 1 ]; then mode="all vCPUs busy"; else mode="no added load"; fi
	printf '\nSteal time (%s s, %s)\n' "$SAMPLE_SECS" "$mode"
	if [ "$STEAL_LEVEL" = unavailable ]; then
		row "Average steal" "not reported by this kernel"
	else
		row "Average steal" "${STEAL_PCT} %  [$STEAL_LEVEL]"
		if [ "$MAX_STEAL_CPU" != "-" ]; then
			row "Highest vCPU" "$MAX_STEAL_CPU at ${MAX_STEAL_PCT} %"
		fi
		row "Machine busy" "${BUSY_PCT} %"
	fi

	printf '\nWhat this means\n'
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		printf '%s\n' "$line" | fold -s -w 74 | sed -e 's/ *$//' -e '1s/^/  - /' -e '2,$s/^/    /'
	done <<EOF
$INTERP
EOF
	printf '\n'
}

main() {
	parse_args "$@"
	case "$(uname -s 2>/dev/null)" in
	Linux) ;;
	*) die "this tool runs on Linux only (detected $(uname -s 2>/dev/null || printf unknown))" ;;
	esac
	if [ ! -r /proc/stat ] || [ ! -r /proc/cpuinfo ]; then
		die "/proc/stat and /proc/cpuinfo must be readable; this tool runs on Linux only"
	fi

	trap stop_load EXIT
	trap 'stop_load; exit 130' INT
	trap 'stop_load; exit 143' TERM

	detect_virt
	detect_cpu
	measure_steal
	interpret

	if [ "$OUTPUT_JSON" -eq 1 ]; then
		print_json
	else
		print_text
	fi
}

main "$@"
