#!/usr/bin/env bash

trap "exit 1" TERM
export TOP_PID=$$


##### DEFINE GLOBALS #####

# Colors
NOCOLOR='\033[0m'
#RED='\033[0;31m'
#GREEN='\033[0;32m'
#ORANGE='\033[0;33m'
#BLUE='\033[0;34m'
#PURPLE='\033[0;35m'
#CYAN='\033[0;36m'
LIGHTGRAY='\033[0;37m'
#DARKGRAY='\033[1;30m'
LIGHTRED='\033[1;31m'
LIGHTGREEN='\033[1;32m'
YELLOW='\033[1;33m'
LIGHTBLUE='\033[1;34m'
#LIGHTPURPLE='\033[1;35m'
#LIGHTCYAN='\033[1;36m'
WHITE='\033[1;37m'

# File/path locations
PREFSFILE="/root/adsb_docker_install.prefs"
LOGFILE="/tmp/adsb_docker_install.log"
REPO_PATH_DOCKER_COMPOSE="/tmp/adsb_docker_install_docker_compose"
REPO_PATH_RTLSDR="/tmp/adsb_docker_install_rtlsdr"

# Repository URLs
REPO_URL_DOCKER_COMPOSE="https://github.com/docker/compose.git"
REPO_URL_RTLSDR="git://git.osmocom.org/rtl-sdr"

# List of RTL-SRD devices (will be populated by script)
RTLSDR_DEVICES=()

# List of kernel modules to blacklist on the host
RTLSDR_MODULES_TO_BLACKLIST=()
RTLSDR_MODULES_TO_BLACKLIST+=(rtl2832_sdr)
RTLSDR_MODULES_TO_BLACKLIST+=(dvb_usb_rtl28xxu)
RTLSDR_MODULES_TO_BLACKLIST+=(rtl2832)

##### DEFINE FUNCTIONS #####

function logger() {
    # Logs messages to the console
    # $1 = stage (string in square brackets at the beginning)
    # $2 = the message to log
    # $3 = the colour (optional)
    # ----------------------------
    if [[ -n "$3" ]]; then
        echo -e "${3}$(date -Iseconds) [$1] ${2}${NOCOLOR}"
    else
        echo "$(date -Iseconds) [$1] $2"
    fi
    echo "$(date -Iseconds) [$1] $2" >> "$LOGFILE"
}

function logger_logfile_only() {
    # Logs messages to the console
    # $1 = stage (string in square brackets at the beginning)
    # $2 = the message to log
    # ----------------------------
    echo "$(date -Iseconds) [$1] $2" >> "$LOGFILE"
}

function exit_failure() {
    echo ""
    echo "Installation has failed. A log file containing troubleshooting information is located at:"
    echo "$LOGFILE"
    echo "If opening a GitHub issue for assistance, please attach the contents of this file."
    echo ""
    kill -s TERM $TOP_PID
}

function update_apt_repos() {
    logger "update_apt_repos" "Performing 'apt-get update'..." "$LIGHTBLUE"
    if apt-get update -y >> "$LOGFILE" 2>&1; then
        logger "update_apt_repos" "'apt-get update' was successful!" "$LIGHTGREEN"
    fi
}

function is_git_installed() {
    # Check if git is installed
    logger_logfile_only "install_git" "Checking if git is installed"
    if which git >> "$LOGFILE" 2>&1; then
        # git is already installed
        logger "install_git" "git is already installed!" "$LIGHTGREEN"
    else
        return 1
    fi
}

function install_git() {
    logger "install_git" "Installing git..." "$LIGHTBLUE"
    # Attempt download of docker script
    if apt-get install -y git >> "$LOGFILE" 2>&1; then
        logger "install_docker" "git installed successfully!" "$LIGHTGREEN"
    else
        logger "install_git" "ERROR: Could not install git via apt-get :-(" "$LIGHTRED"
        exit_failure
    fi
}

function install_docker() {

    # Check if docker is installed
    logger_logfile_only "install_docker" "Checking if docker is installed"
    if which docker >> "$LOGFILE" 2>&1; then

        # Docker is already installed
        logger "install_docker" "Docker is already installed!" "$LIGHTGREEN"

        # Check to see if docker requires an update
        logger_logfile_only "install_docker" "Checking to see if docker components require an update"
        if [[ "$(apt-get -u --just-print upgrade | grep -c docker-ce)" -gt "0" ]]; then
            logger_logfile_only "install_docker" "Docker components DO require an update"

            # Check if containers are running, if not, attempt to upgrade to latest version
            logger_logfile_only "install_docker" "Checking if containers are running"
            if [[ "$(docker ps -q)" -gt "0" ]]; then
                
                # Containers running, don't update
                logger "install_docker" "WARNING: Docker components require an update, but you have running containers. Not updating docker, you will need to do this manually." "$YELLOW"

            else

                # Containers not running, do update
                logger "install_docker" "Docker components require an update. Performing update..." "$LIGHTBLUE"
                if apt-get upgrade -y docker-ce >> "$LOGFILE" 2>&1; then

                    # Docker upgraded OK!
                    logger "install_docker" "Docker upgraded successfully!" "$LIGHTGREEN"

                else

                    # Docker upgrade failed
                    logger "install_docker" "ERROR: Problem updating docker :-(" "$LIGHTRED"
                    exit_failure

                fi
            fi

        else
            logger_logfile_only "install_docker" "Docker components DO NOT require an update"
        fi

    else

        # Docker is not installed
        logger "install_docker" "Installing docker..." "$LIGHTBLUE"

        # Attempt download of docker script
        logger_logfile_only "install_docker" "Attempt download of get-docker.sh script"
        if curl -o /tmp/get-docker.sh -fsSL https://get.docker.com >> "$LOGFILE" 2>&1; then
            logger_logfile_only "install_docker" "get-docker.sh script downloaded OK"
        else
            logger "install_docker" "ERROR: Could not download get-docker.sh script from https://get.docker.com :-(" "$LIGHTRED"
            exit_failure
        fi

        # Attempt to run docker script
        logger_logfile_only "install_docker" "Attempt to run get-docker.sh script"
        if sh /tmp/get-docker.sh >> "$LOGFILE" 2>&1; then
            logger "install_docker" "Docker installed successfully!" "$LIGHTGREEN"
        else
            logger "install_docker" "ERROR: Problem running get-docker.sh installation script :-(" "$LIGHTRED"
            exit_failure
        fi
    fi
}

function install_docker_compose() {

    local docker_compose_version
    local docker_compose_version_latest

    # get latest version of docker-compose
    logger "install_docker_compose" "Querying for latest version of docker-compose..." "$LIGHTBLUE"

    # clone docker-compose repo
    logger_logfile_only "install_docker_compose" "Attempting clone of docker-compose git repo"
    if git clone "$REPO_URL_DOCKER_COMPOSE" "$REPO_PATH_DOCKER_COMPOSE" >> "$LOGFILE" 2>&1; then
        # do nothing
        :
    else
        logger "install_docker_compose" "ERROR: Problem getting latest docker-compose version :-(" "$LIGHTRED"
        exit_failure
    fi
    # get latest tag version from cloned repo
    logger_logfile_only "install_docker_compose" "Attempting to get latest tag from cloned docker-compose git repo"
    pushd "$REPO_PATH_DOCKER_COMPOSE" >> "$LOGFILE" 2>&1 || exit_failure
    if docker_compose_version_latest=$(git tag --sort="-creatordate" | head -1); then
        # do nothing
        :
    else
        logger "install_docker_compose" "ERROR: Problem getting latest docker-compose version :-(" "$LIGHTRED"
        exit_failure
    fi
    popd >> "$LOGFILE" 2>&1 || exit_failure
    # clean up temp downloaded docker_compose repo
    rm -r "$REPO_PATH_DOCKER_COMPOSE"

    # Check if docker_compose is installed
    logger_logfile_only "install_docker_compose" "Checking if docker-compose is installed"
    if which docker-compose >> "$LOGFILE" 2>&1; then

        # docker_compose is already installed
        logger_logfile_only "install_docker_compose" "docker-compose is already installed, attempting to get version information:"
        if docker-compose version >> "$LOGFILE" 2>&1; then
            # do nothing
            :
        else
            logger "install_docker_compose" "ERROR: Problem getting docker-compose version :-(" "$LIGHTRED"
            exit_failure
        fi
        docker_compose_version=$(docker-compose version | grep docker-compose | cut -d ',' -f 1 | rev | cut -d ' ' -f 1 | rev)

        # check version of docker-compose vs latest
        logger_logfile_only "install_docker_compose" "Checking version of installed docker-compose vs latest docker-compose"
        if [[ "$docker_compose_version" == "$docker_compose_version_latest" ]]; then
            logger "install_docker_compose" "docker-compose is already installed, and running the latest version!" "$LIGHTGREEN"
        else

            # remove old versions of docker-compose
            logger "install_docker_compose" "Attempting to remove previous outdated versions of docker-compose..." "$YELLOW"
            while which docker-compose >> "$LOGFILE" 2>&1; do

                # if docker-compose was installed via apt-get
                if [[ $(dpkg --list | grep -c docker-compose) -gt "0" ]]; then
                    logger_logfile_only "install_docker_compose" "Attempting 'apt-get remove -y docker-compose'..."
                    if apt-get remove -y docker-compose >> "$LOGFILE" 2>&1; then
                        # do nothing
                        :
                    else
                        logger "install_docker_compose" "ERROR: Problem uninstalling outdated docker-compose :-(" "$LIGHTRED"
                        exit_failure
                    fi
                elif which pip >> "$LOGFILE" 2>&1; then
                    if [[ $(pip list | grep -c docker-compose) -gt "0" ]]; then
                        logger_logfile_only "install_docker_compose" "Attempting 'pip uninstall -y docker-compose'..."
                        if pip uninstall -y docker-compose >> "$LOGFILE" 2>&1; then
                            # do nothing
                            :
                        else
                            logger "install_docker_compose" "ERROR: Problem uninstalling outdated docker-compose :-(" "$LIGHTRED"
                            exit_failure
                        fi
                    fi
                elif [[ -f "/usr/local/bin/docker-compose" ]]; then
                    logger_logfile_only "install_docker_compose" "Attempting 'mv /usr/local/bin/docker-compose /usr/local/bin/docker-compose.oldversion'..."
                    if mv -v "/usr/local/bin/docker-compose" "/usr/local/bin/docker-compose.oldversion.$(date +%s)" >> "$LOGFILE" 2>&1; then
                        # do nothing
                        :
                    else
                        logger "install_docker_compose" "ERROR: Problem uninstalling outdated docker-compose :-(" "$LIGHTRED"
                        exit_failure
                    fi
                else
                    logger_logfile_only "install_docker_compose" "Unsupported docker-compose installation method detected."
                    logger "install_docker_compose" "ERROR: Problem uninstalling outdated docker-compose :-(" "$LIGHTRED"
                    exit_failure
                fi
            done

            # Install current version of docker-compose as a container
            logger "install_docker_compose" "Installing docker-compose..." "$LIGHTBLUE"
            logger_logfile_only "install_docker_compose" "Attempting download of latest docker-compose container wrapper script"
            if curl -L --fail "https://github.com/docker/compose/releases/download/$docker_compose_version_latest/run.sh" -o /usr/local/bin/docker-compose >> "$LOGFILE" 2>&1; then
                logger_logfile_only "install_docker_compose" "Download of latest docker-compose container wrapper script was OK"

                # Make executable
                logger_logfile_only "install_docker_compose" "Attempting 'chmod a+x /usr/local/bin/docker-compose'..."
                if chmod -v a+x /usr/local/bin/docker-compose >> "$LOGFILE" 2>&1; then
                    logger_logfile_only "install_docker_compose" "'chmod a+x /usr/local/bin/docker-compose' was successful"

                    # Make sure we can now run docker-compose and it is the latest version
                    docker_compose_version=$(docker-compose version | grep docker-compose | cut -d ',' -f 1 | rev | cut -d ' ' -f 1 | rev)
                    if [[ "$docker_compose_version" == "$docker_compose_version_latest" ]]; then
                        logger "install_docker_compose" "docker-compose installed successfully!" "$LIGHTGREEN"
                    else
                        logger "install_docker_compose" "ERROR: Issue running newly installed docker-compose :-(" "$LIGHTRED"
                        exit_failure
                    fi
                else
                    logger "install_docker_compose" "ERROR: Problem chmodding docker-compose container wrapper script :-(" "$LIGHTRED"
                    exit_failure
                fi
            else
                logger "install_docker_compose" "ERROR: Problem downloading docker-compose container wrapper script :-(" "$LIGHTRED"
                exit_failure
            fi
        fi
    
    else

        # Install current version of docker-compose as a container
        logger "install_docker_compose" "Installing docker-compose..." "$LIGHTBLUE"
        logger_logfile_only "install_docker_compose" "Attempting download of latest docker-compose container wrapper script"
        if curl -L --fail "https://github.com/docker/compose/releases/download/$docker_compose_version_latest/run.sh" -o /usr/local/bin/docker-compose >> "$LOGFILE" 2>&1; then
            logger_logfile_only "install_docker_compose" "Download of latest docker-compose container wrapper script was OK"

            # Make executable
            logger_logfile_only "install_docker_compose" "Attempting 'chmod a+x /usr/local/bin/docker-compose'..."
            if chmod -v a+x /usr/local/bin/docker-compose >> "$LOGFILE" 2>&1; then
                logger_logfile_only "install_docker_compose" "'chmod a+x /usr/local/bin/docker-compose' was successful"

                # Make sure we can now run docker-compose and it is the latest version
                docker_compose_version=$(docker-compose version | grep docker-compose | cut -d ',' -f 1 | rev | cut -d ' ' -f 1 | rev)
                if [[ "$docker_compose_version" == "$docker_compose_version_latest" ]]; then
                    logger "install_docker_compose" "docker-compose installed successfully!" "$LIGHTGREEN"
                else
                    logger "install_docker_compose" "ERROR: Issue running newly installed docker-compose :-(" "$LIGHTRED"
                    exit_failure
                fi
            else
                logger "install_docker_compose" "ERROR: Problem chmodding docker-compose container wrapper script :-(" "$LIGHTRED"
                exit_failure
            fi
        else
            logger "install_docker_compose" "ERROR: Problem downloading docker-compose container wrapper script :-(" "$LIGHTRED"
            exit_failure
        fi
    fi
}

function yes_or_no_input() {
    # Get yes or no input from user
    # $1 = user prompt
    # $2 = previous value (optional)
    # -----------------    
    local valid_input
    valid_input=0
    while [[ "$valid_input" -ne 1 ]]; do
        echo -ne "${LIGHTGRAY}$1 "
        if [[ -n "$2" ]]; then
            echo -n "(previously: $2) "
        fi
        echo -ne "${WHITE}[y/n]${NOCOLOR}"
        read -r -n 1 USER_OUTPUT
        echo ""
        case "$USER_OUTPUT" in
            y | Y)
                return 0
                ;;
            n | N)
                return 1
                ;;
            *)
                echo -e "${YELLOW}Please respond with 'y' or 'n'!${NOCOLOR}"
                ;;
        esac
    done
}

function find_rtlsdr_devices() {

    echo -e "${WHITE}===== Looking for RTL-SDR Devices =====${NOCOLOR}"
    echo ""

    # clone rtl-sdr repo
    logger_logfile_only "find_rtlsdr_devices" "Attempting to clone RTL-SDR repo..."
    if git clone --depth 1 "$REPO_URL_RTLSDR" "$REPO_PATH_RTLSDR" >> "$LOGFILE" 2>&1; then
        logger_logfile_only "find_rtlsdr_devices" "Clone of RTL-SDR repo OK"
    else
        logger "find_rtlsdr_devices" "ERROR: Problem cloneing RTL-SDR repo :-(" "$LIGHTRED"
        exit_failure
    fi

    # ensure the rtl-sdr.rules file exists
    if [[ -e "$REPO_PATH_RTLSDR/rtl-sdr.rules" ]]; then

        # loop through each line of rtl-sdr.rules and look for radio
        while read -r line; do

            # only care about lines with radio info
            if echo "$line" | grep 'SUBSYSTEMS=="usb"' > /dev/null 2>&1; then

                # get idVendor & idProduct to look for
                idVendor=$(echo "$line" | grep -oP 'ATTRS\{idVendor\}=="\K[0-9a-f]{4}')
                idProduct=$(echo "$line" | grep -oP 'ATTRS\{idProduct\}=="\K[0-9a-f]{4}')

                # look for the USB devices
                for lsusbline in $(lsusb -d "$idVendor:$idProduct"); do

                    # get bus & device number
                    usb_bus=$(echo "$lsusbline" | grep -oP '^Bus \K\d{3}')
                    usb_device=$(echo "$lsusbline" | grep -oP '^Bus \d{3} Device \K\d{3}')

                    # add to list of radios
                    if [[ -c "/dev/bus/usb/$usb_bus/$usb_device" ]]; then
                        echo " * Found RTL-SDR device at /dev/bus/usb/$usb_bus/$usb_device"
                        RTLSDR_DEVICES+=("/dev/bus/usb/$usb_bus/$usb_device")
                    fi

                done
            fi 

        done < "$REPO_PATH_RTLSDR/rtl-sdr.rules"

    else
        logger "find_rtlsdr_devices" "ERROR: Could not find rtl-sdr.rules :-(" "$LIGHTRED"
        exit_failure
    fi

    # clean up rtl-sdr repo
    rm -r "$REPO_PATH_RTLSDR"
}

function show_preferences() {

    echo ""
    echo -e "${WHITE}===== Configured Preferences =====${NOCOLOR}"
    echo ""

    # ADSBx
    if [[ "$FEED_ADSBX" == "y" ]]; then
        echo " * ADSB-Exchange docker container will be created and configured"
    else
        echo " * No feeding to ADSB-Exchange"
    fi

    # FR24
    if [[ "$FEED_FLIGHTRADAR24" == "y" ]]; then
        echo " * Flightradar24 docker container will be created and configured"
    else
        echo " * No feeding to Flightradar24"
    fi

    # Opensky
    if [[ "$FEED_OPENSKY" == "y" ]]; then
        echo " * OpenSky Network docker container will be created and configured"
    else
        echo " * No feeding to OpenSky Network"
    fi

    # FlightAware
    if [[ "$FEED_FLIGHTAWARE" == "y" ]]; then
        echo " * FlightAware (piaware) docker container will be created and configured"
    else
        echo " * No feeding to FlightAware"
    fi

    # Planefinder
    if [[ "$FEED_PLANEFINDER" == "y" ]]; then
        echo " * PlaneFinder docker container will be created and configured"
    else
        echo " * No feeding to PlaneFinder"
    fi

    # RADARBOX
    if [[ "$FEED_RADARBOX" == "y" ]]; then
        echo " * AirNav RadarBox docker container will be created and configured"
    else
        echo " * No feeding to AirNav RadarBox"
    fi
    echo ""
}

function get_preferences() {
    echo ""
    echo -e "${WHITE}===== Input Preferences =====${NOCOLOR}"
    # Delete prefs file if it exists
    rm "$PREFSFILE" > /dev/null 2>&1 || true
    touch "$PREFSFILE"
    if yes_or_no_input "Do you want to feed ADS-B Exchange (adsbexchange.com)?" "$FEED_ADSBX"; then
        echo "FEED_ADSBX=\"y\"" >> "$PREFSFILE"
    else
        echo "FEED_ADSBX=\"n\"" >> "$PREFSFILE"
    fi
    if yes_or_no_input "Do you want to feed Flightradar24 (flightradar24.com)?" "$FEED_FLIGHTRADAR24"; then
        echo "FEED_FLIGHTRADAR24=\"y\"" >> "$PREFSFILE"
    else
        echo "FEED_FLIGHTRADAR24=\"n\"" >> "$PREFSFILE"
    fi
    if yes_or_no_input "Do you want to feed OpenSky Network (opensky-network.org)?" "$FEED_OPENSKY"; then
        echo "FEED_OPENSKY=\"y\"" >> "$PREFSFILE"
    else
        echo "FEED_OPENSKY=\"n\"" >> "$PREFSFILE"
    fi
    if yes_or_no_input "Do you want to feed FlightAware (flightaware.com)?" "$FEED_FLIGHTAWARE"; then
        echo "FEED_FLIGHTAWARE=\"y\"" >> "$PREFSFILE"
    else
        echo "FEED_FLIGHTAWARE=\"n\"" >> "$PREFSFILE"
    fi
    if yes_or_no_input "Do you want to feed PlaneFinder (planefinder.net)?" "$FEED_PLANEFINDER"; then
        echo "FEED_PLANEFINDER=\"y\"" >> "$PREFSFILE"
    else
        echo "FEED_PLANEFINDER=\"n\"" >> "$PREFSFILE"
    fi
    if yes_or_no_input "Do you want to feed AirNav RadarBox (radarbox.com)?" "$FEED_RADARBOX"; then
        echo "FEED_RADARBOX=\"y\"" >> "$PREFSFILE"
    else
        echo "FEED_RADARBOX=\"n\"" >> "$PREFSFILE"
    fi
    echo ""
}

function unload_rtlsdr_kernel_modules() {
    echo ""
    echo -e "${WHITE}===== Kernel Modules =====${NOCOLOR}"
    echo ""
    for modulename in "${RTLSDR_MODULES_TO_BLACKLIST[@]}"; do
        if lsmod | grep -i "$modulename" > /dev/null 2>&1; then
            if yes_or_no_input "Module '$modulename' must be unloaded to continue. Is this OK?"; then
                if rmmod "$modulename"; then
                    logger "unload_rtlsdr_kernel_modules" "Module '$modulename' unloaded successfully!" "$LIGHTGREEN"
                else
                    logger "unload_rtlsdr_kernel_modules" "ERROR: Could not unload module '$modulename' :-(" "$LIGHTRED"
                    exit_failure
                fi
                echo ""
            else
                echo "Not proceeding."
                echo ""
                exit 1
            fi
        fi
    done
}

function set_rtlsdr_serial_to_00001090() {
    echo ""
    echo -e "${WHITE}===== RTL-SDR Serial ===== ${NOCOLOR}"
    echo ""

    # get current serial number of radio
    docker run --rm -it --device="${RTLSDR_DEVICES[0]}":"${RTLSDR_DEVICES[0]}" --entrypoint rtl_eeprom mikenye/readsb # TODO: greppage

    # set current serial number of radio
    docker run --rm -it --device="${RTLSDR_DEVICES[0]}":"${RTLSDR_DEVICES[0]}" --entrypoint rtl_eeprom mikenye/readsb -s 00001090 # TODO: yessage

}

##### MAIN SCRIPT #####

# Initialise log file
logger_logfile_only "main" "Script started"
#shellcheck disable=SC2128,SC1102
command_line="$(printf %q "$BASH_SOURCE")$((($#)) && printf ' %q' "$@")"
logger_logfile_only "main" "Full command line: $command_line"

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root! Try 'sudo $command_line'" 
   exit 1
fi

# Get git to download list of supported rtl-sdr radios
if ! is_git_installed; then
    echo ""
    echo -e "${WHITE}===== Installing 'git' =====${NOCOLOR}"
    echo ""
    echo "This script needs to install the 'git' utility, which is used for:"
    echo " * Retrieving the supported list of RTL-SDR devices from the rtl-sdr repository"
    echo " * Cloning the 'docker-compose' repository to determine the latest version"
    echo ""
    if ! yes_or_no_input "May this script install the 'git' utility?"; then
        echo "Not proceeding."
        echo ""
        exit 1
    else
        install_git
    fi
    echo ""
fi

# Unload and blacklist rtlsdr kernel modules
unload_rtlsdr_kernel_modules

# Look for RTL-SDR radios
find_rtlsdr_devices
echo -n "Found ${#RTLSDR_DEVICES[@]} "
if [[ "${#RTLSDR_DEVICES[@]}" -gt 1 ]]; then
    echo "radios."
elif [[ "${#RTLSDR_DEVICES[@]}" -eq 0 ]]; then
    echo "radios."
else
    echo "radio."
fi

# If more than one radio is detected, then ask the user to unplug all other radios except the one they wish to use for ADSB 1090MHz reception.
if [[ "${#RTLSDR_DEVICES[@]}" -gt 1 ]]; then
    echo ""
    echo "More than one RTL-SDR device was found. Please un-plug all RTL-SDR devices, except the device you wish to use for ADS-B (1090MHz) reception."
    echo ""
    exit 1
fi

# If only one radio present, check serial. If not 00001090 then change to this
RTLSDR_ADSB_

# Get/Set preferences
confirm_prefs=0
while [[ "$confirm_prefs" -eq "0" ]]; do
    if [[ -e "$PREFSFILE" ]]; then
        #shellcheck disable=SC1090
        source "$PREFSFILE"
        show_preferences
        if yes_or_no_input "Do you want to change these preferences?"; then
            get_preferences
        else
            break
        fi
    else
        get_preferences
    fi
done


# TODO write preferences out to a file just in case this fails

# Final go-ahead
echo ""
echo -e "${WHITE}===== FINAL CONFIRMATION =====${NOCOLOR}"
echo ""
if ! yes_or_no_input "Are you sure you want to proceed?"; then
    echo "Not proceeding."
    echo ""
    exit 1
fi
echo ""

# Install docker
install_docker

# Install git - requirement for docker-compose (to get latest version)
update_apt_repos
install_git

# Install docker-compose
install_docker_compose

echo ""