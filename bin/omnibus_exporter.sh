#!/bin/bash
#-------------------------------------------------------------------------------
#  File       : omnibus_exporter.sh
#  Project    : MnEaaS
#  Author     : Felipe Silveira (fsilveir@br.ibm.com)
#  Repository : https://github.ibm.com/fsilveir/netcool-exporter
#
#-------------------------------------------------------------------------------
#  SCRIPT DESCRIPTION
#-------------------------------------------------------------------------------
#
#  Synopsis   : This script will collect information from Tivoli OMNibus 
#               ObjectServer, so that it can be instrumented directly to a
#               Prometheus monitoring system.
#
#  Parameters : None
#  Environment: Unix, Linux
#
#-------------------------------------------------------------------------------
# Global Variables
#-------------------------------------------------------------------------------

NOW=$(date +"%F")
USERID=$(whoami)
OMNIUSER="ncosys"
BASEDIR="/opt/IBM/GSMA/utils/netcool_exporter"
LOG_FILE="$BASEDIR/logs/omnibus_collector_$NOW.log"
CONF_FILE="$BASEDIR/config/omnibus_collector.conf"
TEMP_FILE="$BASEDIR/temp/omnibus_collector.workfile"
LOCK_FILE="$BASEDIR/temp/run.lock"

#-------------------------------------------------------------------------------
# Functions
#-------------------------------------------------------------------------------

checkRequirements() {
    # Check if required userid is being used
    if [[ ${USERID} != "$OMNIUSER" ]] ; then
        printf "ERROR: Please execute this utility with '%s' user ", "$OMNIUSER"
        printf "instead of '%s'. Exiting!\n", "$USERID"
        exit 2
    fi

    # Check if OMNIHOME environment variable is defined
    if [ -z "$OMNIHOME" ]; then
        printf "ERROR: Environment variable '\$OMNIHOME' not defined. Exiting!\n'"
        exit 2
    fi
    
    # Check if required directories exist
    for dir_name in "$OMNIHOME" \
                    "$BASEDIR" \
                    "$BASEDIR/logs" \
                    "$BASEDIR/config" \
                    "$BASEDIR/temp" \
                    "$BASEDIR/sql"
    do
        if [ ! -d "$dir_name" ] ; then
            printf "ERROR: Cannot find or access '%s' please ", "${dir_name}"
            printf "check if you've configured the script accordingly or if "
            printf "the proper permissions are set. Exiting!\n\n"
            exit 2
        fi
    done

    # Check if required files exist
    for file_name in "$CONF_FILE" \
                     "$OMNIHOME/bin/nco_sql" \
                     "$BASEDIR/sql/evtTotal.sql" \
                     "$BASEDIR/sql/evtCustomers.sql" \
                     "$BASEDIR/sql/zticketState.sql" \
                     "$BASEDIR/sql/zprocessState.sql" 
    do
        if [ ! -f "$file_name" ] ; then
            printf "ERROR: Cannot find or access '%s' please ", "${file_name}"
            printf "check if you've configured the script accordingly or "
            printf "if the proper permissions are set. Exiting!\n\n"
            exit 2
        fi
    done

    # Check if lock file exists
    if [ -f "$LOCK_FILE" ]; then
        echo "ERROR: Lock file exists. Exiting!"
        exit 2
    fi
}

# Logging function
logWrite() {
    printf "[%s][$(date)] - ${*}\n", "${USERID}" >> "${LOG_FILE}"
}

# Get values from output
getValue() {
    sed '1,2d' "$TEMP_FILE" | grep -Ev "affected|^$" | while read value state
    do
        if [ "$state" = "${*}" ]; then
            echo "$value"
        fi
    done
}

# Extracts list of existing customer codes, and creats a temporary sql
# to extract separated counters to each specific customer
printCustomerData() {
    logWrite "INFO: Extracting customer metrics from '$OMNI_SERVER'"
    "$OMNIHOME/bin/nco_sql" -server "$OMNI_SERVER" \
                            -user "$NC_USER" \
                            -password "$NC_PASS" \
                            -i "$BASEDIR/sql/evtCustomers.sql" \
                            -networktimeout 5 \
                            | sed '1,2d' \
                            | head -n -2 > "$TEMP_FILE"

    while read ccode value
    do
        if [[ $ccode == "" ]] ; then
            temp_query="${BASEDIR}/temp/unknown_evtCustomers.sql"
            temp_workfile="${BASEDIR}/temp/unknown.workfile"
            logWrite "INFO: Extracting 'unknown' customer metrics from '$OMNI_SERVER'"
            printf "select '\\\'' + TicketStatus + '\\\'' FROM alerts.status where CustomerCode='';\ngo\n" > "$temp_query"
            
        else
            temp_query="${BASEDIR}/temp/${ccode}_evtCustomers.sql"
            temp_workfile="${BASEDIR}/temp/${ccode}.workfile"
            logWrite "INFO: Extracting '$ccode' customer metrics from '$OMNI_SERVER'"
            printf "select '\\\'' + TicketStatus + '\\\'' FROM alerts.status where CustomerCode='%s';\ngo\n", "$ccode" > "$temp_query"
        fi

        "$OMNIHOME/bin/nco_sql" -server "$OMNI_SERVER" \
                                -user "$NC_USER" \
                                -password "$NC_PASS" \
                                -i "$temp_query" \
                                -networktimeout 5 \
                                | sed '1,2d' \
                                | head -n -2 > "$temp_workfile"

        sort "${temp_workfile}" | uniq -c | while read cus_value cus_state_temp
        do
            if [[ $cus_state_temp == "''" ]] ; then
                cus_state="unknown"
            else
                cus_state=$(echo "${cus_state_temp}" \
                          | sed "s/'//g" \
                          | sed 's/ /_/g' \
                          | awk '{print tolower($0)}' )
            fi

            if [[ $ccode == "" ]] ; then
                ccode_temp="unknown"
                ccode="$ccode_temp"
            fi

            echo "${NETCOOL_ENV}, ${ccode}, total_evts_${cus_state}, ${cus_value}" \
            && rm -rf "${temp_query:?}"

        done && rm -rf "${temp_workfile:?}"

    done < "$TEMP_FILE" && rm "${TEMP_FILE:?}"
}

printEventTotals() {
    logWrite "INFO: Extracting total of events from '$OMNI_SERVER'"
    
    "$OMNIHOME/bin/nco_sql" -server "$OMNI_SERVER" \
                            -user "$NC_USER" \
                            -password "$NC_PASS" \
                            -i "$BASEDIR/sql/evtTotal.sql" \
                            -networktimeout 5 > "$TEMP_FILE"

    total_evts=$(sed '1,2d' "$TEMP_FILE" | head -n1 | awk '{print $1}')
    
    echo "${NETCOOL_ENV}, all, total_evts_all, ${total_evts}"
}

printZTicketState() {
    logWrite "INFO: Extracting ZTicketState data from '$OMNI_SERVER'"
    
    "$OMNIHOME/bin/nco_sql" -server "$OMNI_SERVER" \
                            -user "$NC_USER" \
                            -password "$NC_PASS" \
                            -i "$BASEDIR/sql/zticketState.sql" \
                            -networktimeout 8 > "$TEMP_FILE"
    
    ztkt_failed=$(getValue 7);[ -z "$ztkt_failed" ] && ztkt_failed=0
    ztkt_none=$(getValue 0);[ -z "$ztkt_none" ] && ztkt_none=0
    ztkt_needed=$(getValue 1);[ -z "$ztkt_needed" ] && ztkt_needed=0
    ztkt_final=$(getValue 11);[ -z "$ztkt_final" ] && ztkt_final=0
    ztkt_inprog=$(getValue 2);[ -z "$ztkt_inprog" ] && ztkt_inprog=0
    ztkt_comp=$(getValue 3);[ -z "$ztkt_comp" ] && ztkt_comp=0
    ztkt_retry=$(getValue 4);[ -z "$ztkt_retry" ] && ztkt_retry=0

    echo "${NETCOOL_ENV}, zticketstate, ztkt_failed, ${ztkt_failed}"
    echo "${NETCOOL_ENV}, zticketstate, ztkt_none, ${ztkt_none}"
    echo "${NETCOOL_ENV}, zticketstate, ztkt_needed, ${ztkt_needed}"
    echo "${NETCOOL_ENV}, zticketstate, ztkt_final, ${ztkt_final}"
    echo "${NETCOOL_ENV}, zticketstate, ztkt_inprog, ${ztkt_inprog}"
    echo "${NETCOOL_ENV}, zticketstate, ztkt_comp, ${ztkt_comp}"
    echo "${NETCOOL_ENV}, zticketstate, ztkt_retry, ${ztkt_retry}"
}

printZProcessState() {
    logWrite "INFO: Extracting ZProcessState data from '$OMNI_SERVER'"
    "$OMNIHOME/bin/nco_sql" -server "$OMNI_SERVER" \
                            -user "$NC_USER" \
                            -password "$NC_PASS" \
                            -i "$BASEDIR/sql/zprocessState.sql" \
                            -networktimeout 8 > "$TEMP_FILE"
    
    zproc_unproc=$(getValue 0);[ -z "$zproc_unproc" ] && zproc_unproc=0
    zproc_enrich=$(getValue 1);[ -z "$zproc_enrich" ] && zproc_enrich=0
    zproc_comp=$(getValue 12);[ -z "$zproc_comp" ] && zproc_comp=0
    zproc_inprog=$(getValue 2);[ -z "$zproc_inprog" ] && zproc_inprog=0
    zproc_failed=$(getValue 22);[ -z "$zproc_failed" ] && zproc_failed=0

    echo "${NETCOOL_ENV}, zprocessstate, zproc_unproc, ${zproc_unproc}"
    echo "${NETCOOL_ENV}, zprocessstate, zproc_enrich, ${zproc_enrich}"
    echo "${NETCOOL_ENV}, zprocessstate, zproc_comp, ${zproc_comp}"
    echo "${NETCOOL_ENV}, zprocessstate, zproc_inprog, ${zproc_inprog}"
    echo "${NETCOOL_ENV}, zprocessstate, zproc_failed, ${zproc_failed}"
}

main () {
    checkRequirements

    logWrite "-------------------------------------------------------------------------------"
    logWrite "INFO: No lock file found, starting..."
    logWrite "INFO: Creating new lock file $LOCK_FILE"
    touch "$LOCK_FILE"
    logWrite "INFO: Reading config file '$CONF_FILE'."
    grep -Ev "^#" "$CONF_FILE" | while IFS=";" read NETCOOL_ENV OMNI_SERVER NC_USER NC_PASS
    do
        printEventTotals
        printZProcessState
        printZTicketState
        printCustomerData
    done
    rm "$LOCK_FILE"
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------

main "$@"

#-------------------------------------------------------------------------------
# End of script
#-------------------------------------------------------------------------------
