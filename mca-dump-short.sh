#!/usr/local/bin/bash
#set -xv
set -uo pipefail


declare ERROR_JSON='{"mcaDumpError":"Error"}'

# thanks @zpolisensky for this contribution
#shellcheck disable=SC2016
PORT_NAMES_AWK='
BEGIN { IFS=" \n"; first=1; countedPortId=0 }
match($0, "^interface 0/[0-9]+$") { 
	portId=substr($2,3)
}
match($0, "^interface [A-z0-9]+$") { 
	countedPortId=countedPortId+1
	portId=countedPortId
}
/description / {
		desc=""
		defaultDesc="Port " portId
		for (i=2; i<=NF; i++) {
			f=$i
			if (i==2) f=substr(f,2)
			if (i==NF) 
				f=substr(f,1,length(f)-1)
			else
				f=f " "
			desc=desc f
		}
		if (first != 1) printf "| "
		first=0
		if ( desc == defaultDesc) 
			desc="-"
		else
			desc="(" desc ")"
		printf ".port_table[" portId-1 "] += { \"port_desc\": \"" desc "\" }"
	}'



# for i in 51 52 53 54 55 56 58; do  echo "-------- 192.168.217.$i"; time mca-dump-short.sh -t SWITCH_DISCOVERY -u patrice -d 192.168.217.$i  | jq | grep -E "model|port_desc"; done
# for i in 50 51 52 53 54 56 59; do  echo "-------- 192.168.207.$i"; time mca-dump-short.sh -t SWITCH_DISCOVERY -u patrice -d 192.168.207.$i  | jq | grep -E "model|port_desc"; done


function retrievePortNamesInto() {
	local LOG_FILE=$1
	local OUTSTREAM="/dev/null"
	local OPTIONS=
 	if [[ -n "${VERBOSE:-}" ]]; then
 		echo spawn ssh -o LogLevel=Error -o StrictHostKeyChecking=accept-new "${PRIVKEY_OPTION}" "${USER}@${TARGET_DEVICE}"  >&2
 	fi
 	if [[ -n "${VERBOSE_PORT_DISCOVERY:-}" ]]; then
 		OPTIONS="-d"
 		OUTSTREAM="/dev/stdout"
 	fi

	
	/usr/bin/expect ${OPTIONS} > ${OUTSTREAM} <<EOD
      set timeout 10

      spawn ssh -o LogLevel=Error -o StrictHostKeyChecking=accept-new ${PRIVKEY_OPTION} ${USER}@${TARGET_DEVICE}
	  send -- "\r"

      expect ".*#"
	  send -- "cat /etc/board.info | grep board.name | cut -d'=' -f2\r"
      expect ".*\r\n"
	  expect {
	  	"USW-Flex-XG\r\n" { 
		  expect -re ".*#"

		  send -- "telnet 127.0.0.1\r\r"
		  expect -re ".*#"
		  
		  send -- "terminal datadump\r"
		  expect -re ".*#"
		  
		  send -- "show run\r"
		  log_file -noappend ${LOG_FILE};
		  expect -re ".*#"
		  
		  send -- "exit\r"
		  log_file;
		  expect -re ".*#"

		  send -- "exit\r" 
		  expect eof
	  	}
	  	
	  	"USW-Aggregation\r\n" { 
		  expect -re ".*#"

		  send -- "cli\r"
		  expect -re ".*#"
		  
		  send -- "terminal length 0\r"
		  expect -re ".*#"
		  
		  send -- "show run\r"
		  log_file -noappend ${LOG_FILE};
		  expect -re ".*#"
		  
		  send -- "exit\r"
		  log_file;
		  expect -re ".*>"

		  send -- "exit\r"
		  expect -re ".*#"

		  
		  send -- "exit\r"
		  expect eof
		  
	  	}	  	
	  	
	  	"USW-Flex\r\n" {
		  log_file -noappend ${LOG_FILE};
		  send_log "interface 0/1\r\n"
		  send_log "description 'Port 1'\r\n"
		  send_log "interface 0/2\r\n"
		  send_log "description 'Port 2;\r\n"
		  send_log "interface 0/3\r\n"
		  send_log "description 'Port 3'\r\n"
		  send_log "interface 0/4\r\n"
		  send_log "description 'Port 4'\r\n"
		  log_file;
	  	 }

	  	-re ".*\r\n" {
		  send -- "telnet 127.0.0.1\r"
		  expect "(UBNT) >"
		  
		  send -- "enable\r"
		  expect "(UBNT) #"
		  
		  send -- "terminal length 0\r"
		  expect "(UBNT) #"
		  
		  send -- "show run\r"
		  log_file -noappend ${LOG_FILE};
		  expect "(UBNT) #"
		  
		  send -- "exit\r"
		  log_file;
		  expect "(UBNT) >"

		  send -- "exit\r"
		  expect ".*#"
		  
		  send -- "exit\r"
		  expect eof
		}
	}
EOD
	if [[ -f "$LOG_FILE" ]]; then 
		if [[ -n "${VERBOSE:-}" ]]; then
			echo "Show Run Begin:-----"
			cat "$LOG_FILE"
			echo "Show Run End:-----"
		fi
		#shellcheck disable=SC2002
		cat "$LOG_FILE" | tr -d '\r' | awk "$PORT_NAMES_AWK" > "${LOG_FILE}.jq"
		rm -f "$LOG_FILE" 2>/dev/null
	else
		if [[ -n "${VERBOSE:-}" ]]; then
			echo "** No Show Run output"
		fi	
	fi

}

function insertPortNamesIntoJson() {
	local JQ_PROGRAM=$1
	local JSON=$2
	if [[ -f "${JQ_PROGRAM}" ]]; then	
		if [[ -n "${VERBOSE:-}" ]]; then
			echo "JQ Program:"
			cat "${JQ_PROGRAM}"
		fi
		echo -n "${JSON}" | jq -r "$(cat "${JQ_PROGRAM}")"
		rm -f "$JQ_PROGRAM" 2>/dev/null
	else
		echo -n "${JSON}"
	fi
}


function usage() {

	local error="${1:-}"
	if [[ -n "${error}" ]]; then
		echo "${error}"
		echo
	fi
	
	cat <<- EOF
	Usage ${0}  -i privateKeyPath -p <passwordFilePath> -u user -v -d targetDevice [-t AP|SWITCH|SWITCH_FEATURE_DISCOVERY|SWITCH_DISCOVERY|UDMP|USG|CK]
	  -i specify private public key pair path
	  -p specify password file path to be passed to sshpass -f. Note if both -i and -p are provided, the password file will be used
	  -u SSH user name for Unifi device
	  -d IP or FQDN for Unifi device
	  -t Unifi device type
	  -v verbose and non compressed output
	  -w verbose output for port discovery
	EOF
	exit 2
}

declare SSHPASS_OPTIONS=
declare PRIVKEY_OPTION=
declare PASSWORD_FILE_PATH=
declare VERBOSE_OPTION=


while getopts 'i:u:t:hd:vp:w' OPT
do
  case $OPT in
    i) PRIVKEY_OPTION="-i "${OPTARG} ;;
    u) USER=${OPTARG} ;;
    t) DEVICE_TYPE=${OPTARG} ;;
    d) TARGET_DEVICE=${OPTARG} ;;
    v) VERBOSE=true ;;
    p) PASSWORD_FILE_PATH=${OPTARG} ;;
    w) VERBOSE_PORT_DISCOVERY=true ;;
    *) usage ;;
  esac
done



if [[ -n "${VERBOSE:-}" ]]; then
        VERBOSE_OPTION="-v"
fi

if [[ -z "${TARGET_DEVICE:-}" ]]; then
	usage "Please specify a target device with -d"
fi

if [[ -z "${USER:-}" ]]; then
	echo "Please specify a username with -u" >&2
	usage
fi

if [[ ${DEVICE_TYPE:-} == 'SWITCH_DISCOVERY' ]]; then
	JQ_PROGRAM=/tmp/unifiSWconf-$RANDOM
	retrievePortNamesInto "$JQ_PROGRAM" &
fi

# {$UNIFI_SSHPASS_PASSWORD_PATH} means the macro didn't resolve in Zabbix
if [[ -n "${PASSWORD_FILE_PATH}" ]] && ! [[ "${PASSWORD_FILE_PATH}" == "{\$UNIFI_SSHPASS_PASSWORD_PATH}" ]]; then 
	if ! [[ -f "${PASSWORD_FILE_PATH}" ]]; then
		echo "Password file not found '$PASSWORD_FILE_PATH'"
		exit 1
	fi
	SSHPASS_OPTIONS="-f ${PASSWORD_FILE_PATH} ${VERBOSE_OPTION}"
	PRIVKEY_OPTION=
fi


if [[ ${DEVICE_TYPE:-} == 'AP' ]]; then
	JQ_OPTIONS='del (.port_table) | del(.radio_table[].scan_table) | del (.vap_table[].sta_table)'
elif [[ ${DEVICE_TYPE:-} == 'SWITCH' ]]; then
	JQ_OPTIONS='del (.port_table[].mac_table)'
elif [[ ${DEVICE_TYPE:-} == 'SWITCH_FEATURE_DISCOVERY' ]]; then
        JQ_OPTIONS="[ { power:  .port_table |  any (  .poe_power >= 0 ) ,\
	total_power_consumed_key_name: \"total_power_consumed\",\
	max_power_key_name: \"max_power\",\
	max_power: .total_max_power,\
	percent_power_consumed_key_name: \"percent_power_consumed\",\
	has_eth1: .has_eth1,\
	has_temperature: .has_temperature,\
	temperature_key_name: \"temperature\",\
        overheating_key_name: \"overheating\",\
	has_fan: .has_fan,\
	fan_level_key_name: \"fan_level\"
	} ]"
elif [[ ${DEVICE_TYPE:-} == 'UDMP' ]]; then
	JQ_OPTIONS='del (.dpi_stats) | del(.fingerprints)'
elif [[ ${DEVICE_TYPE:-} == 'USG' ]]; then
	JQ_OPTIONS='del (.dpi_stats) | del(.fingerprints)'
elif [[ ${DEVICE_TYPE:-} == 'CK' ]]; then
	JQ_OPTIONS= 
elif [[ ${DEVICE_TYPE:-} == 'SWITCH_DISCOVERY' ]]; then
	JQ_OPTIONS='del (.port_table[].mac_table)'
elif [[ -n "${DEVICE_TYPE:-}" ]]; then
	echo "Unknown device Type: '${DEVICE_TYPE:-}'"
	usage
fi
	


INDENT_OPTION="--indent 0"


if [[ -n "${VERBOSE:-}" ]]; then
	INDENT_OPTION=
    echo  'ssh -o LogLevel=Error -o StrictHostKeyChecking=accept-new '"${PRIVKEY_OPTION}" "${USER}@${TARGET_DEVICE}"' "mca-dump" | jq '"${INDENT_OPTION}" "${JQ_OPTIONS:-}"
fi

declare EXIT_CODE=0
declare OUTPUT
if [[ -n "${SSHPASS_OPTIONS:-}" ]]; then
	#shellcheck disable=SC2086
	OUTPUT=$(sshpass ${SSHPASS_OPTIONS} ssh -o LogLevel=Error -o StrictHostKeyChecking=accept-new ${PRIVKEY_OPTION} "${USER}@${TARGET_DEVICE}" mca-dump)
	EXIT_CODE=$?
else 
	#shellcheck disable=SC2086
	OUTPUT=$(ssh -o LogLevel=Error -o StrictHostKeyChecking=accept-new ${PRIVKEY_OPTION} "${USER}@${TARGET_DEVICE}" mca-dump)
	EXIT_CODE=$?
fi

if (( EXIT_CODE != 0 )) || [[ -z "${OUTPUT}" ]]; then
	OUTPUT="${ERROR_JSON}"
	EXIT_CODE=1
else
	#shellcheck disable=SC2086
	OUTPUT=$(echo  "${OUTPUT}" | jq ${INDENT_OPTION} "${JQ_OPTIONS:-}")
	EXIT_CODE=$?
	if (( EXIT_CODE != 0 )) || [[ -z "${OUTPUT}" ]]; then
		OUTPUT="${ERROR_JSON}"
		EXIT_CODE=1
	fi
fi


if [[ ${DEVICE_TYPE:-} == 'SWITCH_DISCOVERY' ]]; then
	wait
	OUTPUT=$(insertPortNamesIntoJson "$JQ_PROGRAM.jq" "${OUTPUT}")
fi

echo -n "${OUTPUT}"
exit $EXIT_CODE


