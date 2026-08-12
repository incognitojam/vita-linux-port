#!/bin/sh
set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
test_case=${1:-all}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/vita-dtb-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fake_cpp="$tmp/fake-cpp"
fake_dtc="$tmp/fake-dtc"
make_cmd=${MAKE_CMD:-make}

cat >"$fake_cpp" <<'EOF'
#!/bin/sh
for arg do
	case "$arg" in
		*.dts)
			cat "$arg"
			exit 0
			;;
	esac
done
echo "fake-cpp: no DTS input" >&2
exit 2
EOF

cat >"$fake_dtc" <<'EOF'
#!/bin/sh
set -eu
out=
input=
mode=dts
while [ "$#" -gt 0 ]; do
	case "$1" in
		-o) out=$2; shift 2 ;;
		-I) mode=$2; shift 2 ;;
		-*) shift ;;
		-) shift ;;
		*) input=$1; shift ;;
	esac
done
test -n "$out"
if [ "$mode" = dtb ]; then
	magic=$(od -An -tx1 -N4 "$input" | tr -d ' \n')
	test "$magic" = d00dfeed
	: >"$out"
else
	printf '\320\r\376\355' >"$out"
	cat "${input:--}" >>"$out"
fi
EOF
chmod +x "$fake_cpp" "$fake_dtc"

new_kernel_tree() {
	kernel=$1
	mkdir -p "$kernel/arch/arm/configs" "$kernel/scripts/dtc"
	: >"$kernel/arch/arm/configs/vita_defconfig"
	cp "$fake_dtc" "$kernel/scripts/dtc/dtc"
}

run_layout_test() {
	layout=$1
	kernel="$tmp/kernel-$layout"
	new_kernel_tree "$kernel"

	case "$layout" in
		root) dts_dir="$kernel/arch/arm/boot/dts" ;;
		sony) dts_dir="$kernel/arch/arm/boot/dts/sony" ;;
		*) echo "unknown layout: $layout" >&2; exit 2 ;;
	esac

	mkdir -p "$dts_dir"
	: >"$dts_dir/vita.dtsi"
	for model in vita1000 vita2000 pstv; do
		printf '/dts-v1/;\n/ { model = "%s"; };\n' "$model" >"$dts_dir/$model.dts"
	done

	"$make_cmd" -s -C "$repo_dir" dtb \
		LINUX_VITA_DIR="$kernel" \
		CPP="$fake_cpp"
	"$make_cmd" -s -C "$repo_dir" verify-dtb \
		LINUX_VITA_DIR="$kernel" >/dev/null

	for model in vita1000 vita2000 pstv; do
		test -s "$dts_dir/$model.dtb" || {
			echo "$layout layout did not produce $model.dtb" >&2
			exit 1
		}
	done
}

run_both_layouts_test() {
	kernel="$tmp/kernel-both"
	new_kernel_tree "$kernel"
	for path in arch/arm/boot/dts arch/arm/boot/dts/sony; do
		dts_dir="$kernel/$path"
		mkdir -p "$dts_dir"
		: >"$dts_dir/vita.dtsi"
		for model in vita1000 vita2000 pstv; do
			printf '/dts-v1/;\n/ { model = "%s"; };\n' "$model" >"$dts_dir/$model.dts"
		done
	done

	"$make_cmd" -s -C "$repo_dir" dtb \
		LINUX_VITA_DIR="$kernel" \
		CPP="$fake_cpp"
	for model in vita1000 vita2000 pstv; do
		test -s "$kernel/arch/arm/boot/dts/sony/$model.dtb"
		test ! -e "$kernel/arch/arm/boot/dts/$model.dtb"
	done
}

run_cpp_failure_test() {
	kernel="$tmp/kernel-cpp-failure"
	new_kernel_tree "$kernel"
	dts_dir="$kernel/arch/arm/boot/dts"
	mkdir -p "$dts_dir"
	: >"$dts_dir/vita.dtsi"
	for model in vita1000 vita2000 pstv; do
		printf '/dts-v1/;\n/ { model = "%s"; };\n' "$model" >"$dts_dir/$model.dts"
	done
	bad_cpp="$tmp/bad-cpp"
	cat >"$bad_cpp" <<'EOF'
#!/bin/sh
printf '/dts-v1/;\n/ {};\n'
exit 42
EOF
	chmod +x "$bad_cpp"

	if "$make_cmd" -s -C "$repo_dir" dtb \
		LINUX_VITA_DIR="$kernel" \
		CPP="$bad_cpp" >"$tmp/cpp-failure.out" 2>&1; then
		echo "failing CPP was masked by the DTB recipe" >&2
		exit 1
	fi
	for model in vita1000 vita2000 pstv; do
		test ! -e "$dts_dir/$model.dtb"
	done
	if find "$dts_dir" -maxdepth 1 -name '.*.dtb.*' | grep -q .; then
		echo "failed build left staging directories behind" >&2
		exit 1
	fi
}

run_invalid_dtb_test() {
	kernel="$tmp/kernel-invalid-dtb"
	new_kernel_tree "$kernel"
	dts_dir="$kernel/arch/arm/boot/dts"
	mkdir -p "$dts_dir"
	: >"$dts_dir/vita.dtsi"
	for model in vita1000 vita2000 pstv; do
		printf 'not a device tree\n' >"$dts_dir/$model.dtb"
	done
	if "$make_cmd" -s -C "$repo_dir" verify-dtb \
		LINUX_VITA_DIR="$kernel" >"$tmp/invalid-dtb.out" 2>&1; then
		echo "verify-dtb accepted invalid artifacts" >&2
		exit 1
	fi
	grep -q 'Invalid .*vita1000.dtb' "$tmp/invalid-dtb.out"
}

run_missing_layout_test() {
	kernel="$tmp/kernel-missing"
	new_kernel_tree "$kernel"
	for model in vita1000 vita2000 pstv; do
		printf 'sentinel\n' >"$kernel/$model.dtb"
	done
	if "$make_cmd" -s -C "$repo_dir" dtb \
		LINUX_VITA_DIR="$kernel" \
		CPP="$fake_cpp" >"$tmp/missing.out" 2>&1; then
		echo "missing DTS layout unexpectedly succeeded" >&2
		exit 1
	fi
	grep -q 'Vita device tree sources not found' "$tmp/missing.out" || {
		echo "missing DTS layout did not fail with the expected diagnostic" >&2
		cat "$tmp/missing.out" >&2
		exit 1
	}

	"$make_cmd" -s -C "$repo_dir" clean LINUX_VITA_DIR="$kernel" >/dev/null
	for model in vita1000 vita2000 pstv; do
		grep -qx sentinel "$kernel/$model.dtb" || {
			echo "clean removed a kernel-root DTB sentinel" >&2
			exit 1
		}
	done

	fake_bin="$tmp/fake-bin"
	mkdir -p "$fake_bin"
	cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
echo called >"$CURL_CALLED"
exit 99
EOF
	chmod +x "$fake_bin/curl"
	if PATH="$fake_bin:$PATH" CURL_CALLED="$tmp/curl-called" \
		"$make_cmd" -s -C "$repo_dir" push \
		LINUX_VITA_DIR="$kernel" >"$tmp/push.out" 2>&1; then
		echo "missing-layout push unexpectedly succeeded" >&2
		exit 1
	fi
	test ! -e "$tmp/curl-called" || {
		echo "push invoked curl before validating the DTS layout" >&2
		exit 1
	}
	grep -q 'Vita device tree sources not found' "$tmp/push.out"
}

run_ci_contract_test() {
	workflow="$repo_dir/.github/workflows/build.yml"
	build_count=$(grep -Ec '^[[:space:]]+(g?make)[[:space:]]+dtb([[:space:]]|$)' "$workflow" || true)
	test "$build_count" -eq 2 || {
		echo "expected Linux and macOS CI to call the outer dtb target; found $build_count calls" >&2
		exit 1
	}
	verify_count=$(grep -Ec '^[[:space:]]+(g?make)[[:space:]]+verify-dtb([[:space:]]|$)' "$workflow" || true)
	test "$verify_count" -eq 2 || {
		echo "expected Linux and macOS CI to call the outer verify-dtb target; found $verify_count calls" >&2
		exit 1
	}
	test_count=$(grep -Ec 'run:[[:space:]]+(g?make)[[:space:]]+test([[:space:]]|$)|^[[:space:]]+(g?make)[[:space:]]+test([[:space:]]|$)' "$workflow" || true)
	test "$test_count" -ge 1 || {
		echo "expected CI to run the build-contract regression suite" >&2
		exit 1
	}
	if grep -q 'scripts/dtc/dtc' "$workflow"; then
		echo "CI still contains a duplicate direct dtc recipe" >&2
		exit 1
	fi
	if grep -q 'linux_vita/arch/arm/boot/dts' "$workflow"; then
		echo "CI still hard-codes a kernel DTS layout" >&2
		exit 1
	fi
}

case "$test_case" in
	root) run_layout_test root ;;
	sony) run_layout_test sony ;;
	both) run_both_layouts_test ;;
	cpp-failure) run_cpp_failure_test ;;
	invalid-dtb) run_invalid_dtb_test ;;
	missing) run_missing_layout_test ;;
	ci) run_ci_contract_test ;;
	all)
		run_layout_test root
		run_layout_test sony
		run_both_layouts_test
		run_cpp_failure_test
		run_invalid_dtb_test
		run_missing_layout_test
		run_ci_contract_test
		;;
	*) echo "usage: $0 [root|sony|both|cpp-failure|invalid-dtb|missing|ci|all]" >&2; exit 2 ;;
esac
