#!/bin/bash
# https://github.com/uJZk/Actions-ImmortalWrt
# Easy Update Script by uJZk
# Modified from [luci-app-easyupdate](https://github.com/sundaqiang/openwrt-packages/tree/master/luci-app-easyupdate)

readonly LOG_MAIN='/tmp/easyupdatemain.log'
readonly LOG_DL='/tmp/easyupdate.log'
readonly LOG_FLASH='/tmp/easyupdate-flash.log'
readonly REL_JSON='/tmp/easyupdate-release.json'
readonly LOCK_FILE='/var/lock/easyupdate.lock'
readonly LOG_MAX=262144

# Release assets carry no version in their filename, so a stale image plus its
# stale sha256sums verify against each other and flash as if current. Every
# download purges both first.
readonly IMG_GLOB='*combined*.img.gz*'

# Asset sources, tried in order. 'direct' is github.com itself; the rest are
# ghproxy-style reverse proxies taking the whole github URL glued onto the
# prefix. They front the download host only -- api.github.com is always direct.
# github.com goes first: the mirrors are community-run, and a lapsed one still
# answers 200 with a parked page. The checksum travels the same route as the
# image, so a proxy rewriting both would still verify -- hence every candidate
# must pass sha256 before it is accepted.
readonly SOURCES='
direct
https://gh-proxy.com/
https://gh.ddlc.top/
https://ghfast.top/
'

# A source can accept the connection and then trickle, burning the whole -m
# budget before the next one is tried. Abandon a slow source instead.
readonly MIN_SPEED=51200
readonly MIN_SPEED_TIME=30

file=''
VERIFIED_FILE=''
REPO_SLUG=''

function writeLog() {
	printf '[%s] %s\n' "$(date +"%Y-%m-%d %H:%M:%S")" "$*" | tee -a "$LOG_MAIN"
}

function rotateLog() {
	if [ -f "$LOG_MAIN" ] && [ "$(wc -c <"$LOG_MAIN")" -gt "$LOG_MAX" ]; then
		: >"$LOG_MAIN"
	fi
	return 0
}

# /tmp is tmpfs: a concurrent run competes for RAM and could start a second
# sysupgrade. Cron plus a manual run makes that reachable.
function acquireLock() {
	command -v flock >/dev/null 2>&1 || return 0
	mkdir -p "${LOCK_FILE%/*}" 2>/dev/null
	{ exec 9>"$LOCK_FILE"; } 2>/dev/null || return 0
	if ! flock -n 9; then
		writeLog 'Another run is already in progress(已有更新任务在运行)'
		exit 1
	fi
}

function checkEnv() {
	if ! type sysupgrade >/dev/null 2>&1; then
		writeLog 'Your firmware does not contain sysupgrade and does not support automatic updates(您的固件未包含sysupgrade,暂不支持自动更新)'
		exit 1
	fi
}

function isVersion() {
	[ "${#1}" -eq 12 ] && [ -z "${1//[0-9]/}" ]
}

function shellHelp() {
	checkEnv
	cat <<EOF
Easy Update Script by uJZk
Your firmware already includes Sysupgrade and supports automatic updates(您的固件已包含sysupgrade,支持自动更新)
参数:
    -c                     Get the cloud firmware version(获取云端固件版本)
    -d                     Download cloud Firmware(下载云端固件)
    -f filename            Flash firmware from /tmp, checksum-verified first(校验后刷写固件)
    -k [filename]          Verify a downloaded firmware against sha256sums(校验已下载固件)
    -u                     One-click firmware update(一键更新固件)
EOF
}

# DISTRIB_GITHUB is '<server_url>/<owner>/<repo>'; splitting on '/' yields
# https: / host / owner / repo. The indices are fixed to that shape.
function githubRepo() {
	local raw parts
	raw=$(sed -n "s/DISTRIB_GITHUB='\(\S*\)'/\1/p" /etc/openwrt_release)
	if [ -z "$raw" ]; then
		writeLog 'DISTRIB_GITHUB is missing from /etc/openwrt_release(读取不到github项目地址)'
		return 1
	fi
	parts=(${raw//\// })
	if [ -z "${parts[2]}" ] || [ -z "${parts[3]}" ]; then
		writeLog "Unparsable github project address(无法解析github项目地址):$raw"
		return 1
	fi
	REPO_SLUG="${parts[2]}/${parts[3]}"
	return 0
}

# One API call per run; unauthenticated api.github.com is rate-limited per IP.
# A failure here must be loud -- treating it as "up to date" makes a router
# stop updating with nothing to see.
function fetchRelease() {
	[ -s "$REL_JSON" ] && return 0
	githubRepo || return 1
	if ! curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 15 -m 120 \
		-o "$REL_JSON" "https://api.github.com/repos/$REPO_SLUG/releases/latest" ||
		[ ! -s "$REL_JSON" ]; then
		rm -f "$REL_JSON"
		writeLog "Cannot read the latest release from github(读取云端release失败):$REPO_SLUG"
		return 1
	fi
	return 0
}

function getCloudVer() {
	checkEnv
	fetchRelease || return 1
	local tag ver
	tag=$(jsonfilter -i "$REL_JSON" -e '@.tag_name')
	# Output keeps the '<12 digits>_<short sha>' shape of DISTRIB_VERSIONS.
	ver=$(printf '%s' "$tag" | sed -n 's/.*\([0-9]\{12\}.*\)/\1/p')
	if ! isVersion "${ver:0:12}"; then
		writeLog "No build timestamp in the release tag(release标签里没有构建时间):$tag"
		return 1
	fi
	printf '%s\n' "$ver"
}

function srcPrefix() {
	if [ "$1" = 'direct' ]; then
		printf ''
	else
		printf '%s' "$1"
	fi
}

# The image loop below walks the sources again: the two fetches fail
# independently.
function fetchSums() {
	local dst="$1" sumsUrl="$2" src prefix
	for src in $SOURCES; do
		prefix=$(srcPrefix "$src")
		if curl -fsL --connect-timeout 15 -m 120 -o "$dst" "${prefix}${sumsUrl}"; then
			writeLog "sha256sums source(校验文件来源):$src"
			return 0
		fi
		writeLog "sha256sums unavailable, next source(校验文件取不到，换下一个源):$src"
		rm -f "$dst"
	done
	return 1
}

function downCloudVer() {
	checkEnv
	fetchRelease || return 1
	local suffix url size need avail src prefix

	writeLog 'Check whether EFI firmware is available(判断是否EFI固件)'
	if [ -d "/sys/firmware/efi/" ]; then
		suffix="combined-efi.img.gz"
	else
		suffix="combined.img.gz"
	fi
	writeLog "Whether EFI firmware is available(是否EFI固件):$suffix"

	writeLog 'Get the cloud firmware link(获取云端固件链接)'
	url=$(jsonfilter -i "$REL_JSON" -e '@.assets[*].browser_download_url' | grep -F -- "$suffix" | head -n1)
	if [ -z "$url" ]; then
		writeLog "No matching asset in the release(release里没有匹配的固件):$suffix"
		return 1
	fi
	writeLog "Cloud firmware link(云端固件链接):$url"

	# Basename, not a fixed path index -- the download URL depth is not a
	# stable contract.
	local fileName="${url##*/}"

	# /tmp is RAM. Running out mid-download leaves a truncated image and no
	# memory left to run sysupgrade in.
	size=$(jsonfilter -i "$REL_JSON" -e "@.assets[@.name=\"$fileName\"].size" 2>/dev/null)
	if [ -n "$size" ] && [ -z "${size//[0-9]/}" ]; then
		avail=$(df -k /tmp | awk 'END {print $(NF-2)}')
		need=$((size / 1024 + 8192))
		if [ -n "$avail" ] && [ "$avail" -lt "$need" ]; then
			writeLog "Not enough space in /tmp(/tmp空间不足): need ${need}K, have ${avail}K"
			return 1
		fi
	fi

	find /tmp -maxdepth 1 -name "$IMG_GLOB" -exec rm -f {} +

	local sumsUrl="${url/${fileName}/sha256sums}"
	if ! fetchSums "/tmp/${fileName}-sha256" "$sumsUrl"; then
		writeLog 'Cannot download sha256sums(下载sha256sums失败)'
		return 1
	fi

	writeLog "Start downloading firmware, log output in $LOG_DL(开始下载固件，日志输出在$LOG_DL)"
	for src in $SOURCES; do
		prefix=$(srcPrefix "$src")
		writeLog "Try download source(尝试下载源):$src"
		if ! curl -fL --connect-timeout 15 -m 3600 \
			--speed-limit "$MIN_SPEED" --speed-time "$MIN_SPEED_TIME" \
			-o "/tmp/${fileName}" "${prefix}${url}" >"$LOG_DL" 2>&1; then
			writeLog "Download error(下载出错):$src, see $LOG_DL"
			rm -f "/tmp/${fileName}"
			continue
		fi
		# Verify inside the loop: a mirror answering 200 with something else
		# costs one retry, not the whole update.
		if checkSha "$fileName" >/dev/null 2>&1; then
			writeLog "Download completes(下载完成):$src"
			file="$fileName"
			return 0
		fi
		writeLog "Checksum mismatch, next source(校验不通过，换下一个源):$src"
		rm -f "/tmp/${fileName}"
	done

	writeLog 'All download sources failed(所有下载源都失败)'
	rm -f "/tmp/${fileName}-sha256"
	return 1
}

function checkSha() {
	local target="${1:-$file}" path line
	if [ -z "$target" ]; then
		for path in /tmp/*; do
			case "${path##*/}" in
			*-combined*.img.gz) target="${path##*/}" ;;
			esac
		done
	fi
	if [ -z "$target" ]; then
		writeLog 'No firmware image found in /tmp(/tmp里没有固件)'
		return 1
	fi
	target="${target##*/}"
	if [ ! -f "/tmp/$target" ] || [ ! -f "/tmp/$target-sha256" ]; then
		writeLog "Firmware or its sha256sums is missing(固件或校验文件缺失):$target"
		return 1
	fi
	line=$(grep -F -- "$target" "/tmp/$target-sha256")
	if [ "$(printf '%s' "$line" | grep -c '')" -ne 1 ]; then
		writeLog "No unique checksum line for the firmware(校验文件里没有唯一匹配行):$target"
		return 1
	fi
	if ! (cd /tmp && printf '%s\n' "$line" | sha256sum -c -); then
		return 1
	fi
	VERIFIED_FILE="$target"
	return 0
}

function flashFirmware() {
	checkEnv
	if [ -z "$file" ]; then
		writeLog 'Please specify the file name(请指定文件名)'
		return 1
	fi
	local target="${file##*/}"
	if [ ! -f "/tmp/$target" ]; then
		writeLog "Firmware not found(找不到固件):/tmp/$target"
		return 1
	fi
	if [ "$VERIFIED_FILE" != "$target" ]; then
		writeLog 'Verify the firmware before flashing(刷写前校验固件)'
		if ! checkSha "$target" >/dev/null 2>&1; then
			writeLog 'Check error, refusing to flash(校验出错，拒绝刷写)'
			return 1
		fi
		writeLog 'Check completes(检查完成)'
	fi
	writeLog "Start flash firmware, log output in $LOG_FLASH(开始刷写固件，日志输出在$LOG_FLASH)"
	# Detach from the terminal: losing the ssh session mid-sysupgrade bricks
	# the box.
	if command -v setsid >/dev/null 2>&1; then
		setsid sysupgrade "/tmp/$target" >"$LOG_FLASH" 2>&1 &
	else
		(
			trap '' HUP
			sysupgrade "/tmp/$target" >"$LOG_FLASH" 2>&1 &
		)
	fi
	return 0
}

function updateCloud() {
	checkEnv
	local lFirVer cFirVer
	writeLog 'Get the local firmware version(获取本地固件版本)'
	lFirVer=$(sed -n "s/DISTRIB_VERSIONS='.*\([0-9]\{12\}\).*'/\1/p" /etc/openwrt_release)
	writeLog "Local firmware version(本地固件版本):$lFirVer"
	if ! isVersion "$lFirVer"; then
		writeLog 'Cannot read the local firmware version(读取不到本地固件版本)'
		return 1
	fi

	writeLog 'Get the cloud firmware version(获取云端固件版本)'
	cFirVer=$(getCloudVer) || return 1
	writeLog "Cloud firmware version(云端固件版本):$cFirVer"
	cFirVer="${cFirVer:0:12}"

	# YYYYMMDDHHMM is zero-padded and monotonic, so a string compare is exact
	# without date(1) parsing.
	if ! [[ "$cFirVer" > "$lFirVer" ]]; then
		writeLog 'Is the latest(已是最新)'
		return 0
	fi

	writeLog 'Need to be updated(需要更新)'
	downCloudVer || return 1
	# downCloudVer returns 0 only after checkSha passed; flashFirmware
	# re-verifies anything it was not handed verified.
	writeLog 'Prepare flash firmware(准备刷写固件)'
	flashFirmware
}

rotateLog

if [ -z "$1" ]; then
	shellHelp
	exit 0
fi

case $1 in
-c)
	getCloudVer
	;;
-d)
	acquireLock
	downCloudVer
	;;
-f)
	acquireLock
	file=$2
	flashFirmware
	;;
-k)
	file=$2
	checkSha
	;;
-u)
	acquireLock
	updateCloud
	;;
*)
	shellHelp
	;;
esac
