#!/bin/sh

#
# Copyright (C) 2018 Chin Huat Ang <chinhuat@gmail.com>
# 
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#

#
# selsta- select STA mode wifi iface
#
# Wifi devices might have multiple STA mode wifi iface defined, but only one
# STA mode wifi iface will work per wifi device. This script checks to see
# which STA mode wifi iface is the best and enables it, while other wifi iface
# will be disabled so that only one STA mode wifi iface is enabled at a time.
#


RADIO=radio0

get_wifi_iface() {
	uci show wireless | grep "wireless\..\+\.device='$RADIO'" | cut -d . -f 2
}

get_sta_wifi_iface() {
	
	for WIFI_IFACE in $(get_wifi_iface); do
		if [ "$(uci get wireless.${WIFI_IFACE}.mode)" == "sta" ]; then
			echo $WIFI_IFACE
		fi
	done
}


#
# Return the equivalent ifname of a wifi iface
#
get_wifi_iface_ifname() {
	
	WIFI_IFACE=$1
	STATUS=$(ubus call network.wireless status)

	COUNT=$(get_wifi_iface | wc -w)
	for N in $(seq 0 $(expr $COUNT - 1)); do
		SECTION=$(echo $STATUS | jsonfilter -e "@.$RADIO.interfaces[$N].section")
		if [ -z "$SECTION" ]; then
			# TODO: instead of checking for non-existent section, we can be more precise by
			#		counting the exact number of wifi iface (AP and STA) enabled
			break
		else
			if [ "$SECTION" == "$WIFI_IFACE" ]; then
				echo $STATUS | jsonfilter -e "@.$RADIO.interfaces[$N].ifname"
			fi		
		fi

	done
}


get_sta_wifi_iface_with_bssid_detected() {


	# TODO: get wlan0 from radio, also need to handle intermittent scan failure
	ALL_BSSID_DETECTED=$(iw wlan0 scan | grep BSS | tr '(' ' ' | awk '{ print $2 }' | tr 'abcdef' 'ABCDEF')

	for WIFI_IFACE in $(get_sta_wifi_iface); do

		BSSID=$(uci get wireless.${WIFI_IFACE}.bssid | tr 'abcdef' 'ABCDEF')

		if echo ${ALL_BSSID_DETECTED/ /\n} | grep $BSSID 1>/dev/null; then
			echo $WIFI_IFACE
		fi
	done
}


get_sta_wifi_iface_with_carrier() {

	for WIFI_IFACE in $(get_sta_wifi_iface); do
		if [ "$(uci get wireless.${WIFI_IFACE}.disabled 2>/dev/null)" != "1" ]; then
			IFNAME=$(get_wifi_iface_ifname $WIFI_IFACE)
			if [ "$(ubus call network.device status | jsonfilter -e "@['$IFNAME'].carrier")" == "true" ]; then
				echo $WIFI_IFACE
			fi
		fi
	done
}


get_best_sta_wifi_iface() {

	KEEP_WIFI_IFACE_WITH_CARRIER=0


	# If there is only one wifi iface in sta mode, do nothing
	
	if [ $(get_sta_wifi_iface | wc -w) -eq 1 ]; then
		return
	fi

	if [ $KEEP_WIFI_IFACE_WITH_CARRIER -eq 1 ]; then
		
		# If there are multiple wifi iface in sta mode and at least one has carrier,
		# make sure only that wifi iface is enabled
	
		STA_WIFI_IFACE_WITH_CARRIER=$(get_sta_wifi_iface_with_carrier)
	
		if [ -n "$STA_WIFI_IFACE_WITH_CARRIER" ]; then
			echo ${STA_WIFI_IFACE_WITH_CARRIER} | cut -d " " -f 1 
			return
		fi	
	fi
	
	
	# If there are multiple wifi iface in sta mode but none have carrier,
	# try to find best wifi iface by matching BSSID with detected ones.
	# And if multiple wifi iface BSSID are detected, use the first one.

	STA_WIFI_IFACE_WITH_BSSID_DETECTED=$(get_sta_wifi_iface_with_bssid_detected)

	if [ -n "$STA_WIFI_IFACE_WITH_BSSID_DETECTED" ]; then
		echo ${STA_WIFI_IFACE_WITH_BSSID_DETECTED} | cut -d " " -f 1 
		return
	fi	


	# If none of the wifi iface BSSID are detected, do nothing
	
}


select_sta_wifi_iface() {

	SELECTED_WIFI_IFACE=$1

	# If no wifi iface specified, do nothing
	if [ -z "$SELECTED_WIFI_IFACE" ]; then
		echo "No wifi interface specified."
		return
	fi


	COMMIT_AND_RESTART=0

	# Make sure only the specified wifi iface is enabled. Also, only update
	# wifi iface state and commit if the current state differs.

	for WIFI_IFACE in $(get_sta_wifi_iface); do
		if [ "$SELECTED_WIFI_IFACE" == "$WIFI_IFACE" ]; then
			if [ "$(uci get wireless.${WIFI_IFACE}.disabled 2>/dev/null)" == "1" ]; then
				echo "Enabling $WIFI_IFACE ssid=$(uci get wireless.${WIFI_IFACE}.ssid) bssid=$(uci get wireless.${WIFI_IFACE}.bssid)"
				uci delete wireless.${WIFI_IFACE}.disabled
				COMMIT_AND_RESTART=1
			fi
		else
			if [ "$(uci get wireless.${WIFI_IFACE}.disabled 2>/dev/null)" != "1" ]; then
				echo "Disabling $WIFI_IFACE ssid=$(uci get wireless.${WIFI_IFACE}.ssid) bssid=$(uci get wireless.${WIFI_IFACE}.bssid)"
				uci set wireless.${WIFI_IFACE}.disabled=1
				COMMIT_AND_RESTART=1
			fi
		fi
	done

	if [ $COMMIT_AND_RESTART -eq 1 ]; then
		echo "Restarting wifi interfaces"
		uci commit wireless
		wifi
	else
		echo "No changes in wifi interface."
	fi
}


select_sta_wifi_iface $(get_best_sta_wifi_iface)
