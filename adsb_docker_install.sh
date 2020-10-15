#!/usr/bin/env bash
# shellcheck disable=SC2028,SC1090

# Disabled check notes:
#   - SC1090: Can't follow non-constant source. Use a directive to specify location.
#       - There are files that are sourced that don't yet exist until runtime.
#   - SC2028: Echo may not expand escape sequences. Use printf.
#       - The way we write out the FR24 / Piaware expect script logs a tonne of these.
#       - We don't want the escape sequences expanded in this instance.
#       - There's probably a better way to write out the expect script (heredoc?)

# Get PID of running instance of this script
export TOP_PID=$$

# Declar traps
trap cleanup EXIT
trap "cleanup; exit 1" TERM

##### DEFINE GLOBALS #####

# Bash CLI Colors
NOCOLOR='\033[0m'
LIGHTGRAY='\033[0;37m'
LIGHTRED='\033[1;31m'
LIGHTGREEN='\033[1;32m'
YELLOW='\033[1;33m'
LIGHTBLUE='\033[1;34m'
WHITE='\033[1;37m'

# File/dir locations
PREFSFILE="/root/adsb_docker_install.prefs"
LOGFILE="/tmp/adsb_docker_install.log"

# Temp files/dirs
FILE_FR24SIGNUP_EXPECT="$(mktemp --suffix=_adsb_docker_install_fr24signup)"
FILE_FR24SIGNUP_LOG="$(mktemp --suffix=_adsb_docker_install_fr24log)"
FILE_PIAWARESIGNUP_EXPECT="$(mktemp --suffix=_adsb_docker_install_fr24signup)"
FILE_PIAWARESIGNUP_LOG="$(mktemp --suffix=_adsb_docker_install_piawarelog)"
REPO_PATH_DOCKER_COMPOSE="$(mktemp -d --suffix="_adsb_docker_install_docker_compose_repo")"
REPO_PATH_RTLSDR="$(mktemp -d --suffix="_adsb_docker_install_rtlsdr_repo")"
# NOTE: If more temp files/dirs are added here, add to cleanup function below

# Temp container IDs
CONTAINER_ID_FR24=
CONTAINER_ID_PIAWARE=
# NOTE: If more temp containers are made, make sure they are cleaned up
# NOTE: Also make sure they are started with '--rm' so they're deleted when killed

# Cleanup function run on script exit (via trap)
function cleanup() {
    # Cleanup of temp files/dirs
    rm -r "$FILE_FR24SIGNUP_EXPECT" > /dev/null 2>&1 || true
    rm -r "$FILE_FR24SIGNUP_LOG" > /dev/null 2>&1 || true
    rm -r "$FILE_PIAWARESIGNUP_LOG" > /dev/null 2>&1 || true
    rm -r "$REPO_PATH_DOCKER_COMPOSE" > /dev/null 2>&1 || true
    rm -r "$REPO_PATH_RTLSDR" > /dev/null 2>&1 || true
    # Cleanup of temp containers
    docker kill "$CONTAINER_ID_FR24" > /dev/null 2>&1 || true
    docker kill "$CONTAINER_ID_PIAWARE" > /dev/null 2>&1 || true
}

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

# Variables that should exist in PREFSFILE
ADSBX_UUID=
ADSBX_SITENAME=
PIAWARE_FEEDER_ID=


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
    echo "If opening a GitHub issue for assistance, be prepared to send this file in. however:"
    echo -e "${LIGHTRED}Please remember to remove any:"
    echo "  - email addresses"
    echo "  - usernames/passwords"
    echo "  - API keys / sharing keys / UUIDs"
    echo "  - your exact location in lat/long"
    echo -e "...and any other sensitive data before posting in a public forum!${NOCOLOR}"
    echo ""
    kill -s TERM $TOP_PID
}

function write_fr24_expectscript() {
    # $1 = container ID of fr24 signup container that's running
    #-----
    source "$PREFSFILE"
    {
        echo '#!/usr/bin/env expect'
        echo 'set timeout 120'
        echo "spawn docker attach $1"
        echo "sleep 3"
        echo "send \"\r\""
        echo 'expect "Step 1.1 - Enter your email address (username@domain.tld)"'
        echo 'expect "$:"'
        echo "send \"${FR24_EMAIL}\r\""
        echo 'expect "Step 1.2 - If you used to feed FR24 with ADS-B data before, enter your sharing key."'
        echo 'expect "$:"'
        echo "send \"\r\""
        echo 'expect "Step 1.3 - Would you like to participate in MLAT calculations? (yes/no)$:"'
        echo "send \"yes\r\""
        echo "expect \"Step 3.A - Enter antenna's latitude (DD.DDDD)\""
        echo 'expect "$:"'
        echo "send \"${FEEDER_LAT}\r\""
        echo "expect \"Step 3.B - Enter antenna's longitude (DDD.DDDD)\""
        echo 'expect "$:"'
        echo "send \"${FEEDER_LONG}\r\""
        echo "expect \"Step 3.C - Enter antenna's altitude above the sea level (in feet)\""
        echo 'expect "$:"'
        echo "send \"${FEEDER_ALT_FT}\r\""
        # TODO - Handle 'Validating email/location information...ERROR'
        echo 'expect "Would you like to continue using these settings?"'
        echo 'expect "Enter your choice (yes/no)$:"'
        echo "send \"yes\r\""
        echo 'expect "Step 4.1 - Receiver selection (in order to run MLAT please use DVB-T stick with dump1090 utility bundled with fr24feed):"'
        echo 'expect "Enter your receiver type (1-7)$:"'
        echo "send \"7\r\""
        echo 'expect "Step 6 - Please select desired logfile mode:"'
        echo 'expect "Select logfile mode (0-2)$:"'
        echo "send \"0\r\""
        echo 'expect "Submitting form data...OK"'
        echo 'expect "+ Your sharing key ("'
        echo 'expect "+ Your radar id is"'
        echo 'expect "Saving settings to /etc/fr24feed.ini...OK"'
    } > "$FILE_FR24SIGNUP_EXPECT"
}

function write_piaware_expectscript() {
    # $1 = container ID of piaware signup container that's running
    #-----
    source "$PREFSFILE"
    {
        echo '#!/usr/bin/env expect'
        echo 'set timeout 120'
        echo "spawn docker logs -f $1"
        echo 'expect " my feeder ID is "'
    } > "$FILE_PIAWARESIGNUP_EXPECT"
}

function welcome_msg() {

cat << "EOM"

  __                  
  \  \     _ _            _    ____  ____        ____
   \**\ ___\/ \          / \  |  _ \/ ___|      | __ )
  X*#####*+^^\_\        / _ \ | | | \___ \ _____|  _ \
   o/\  \              / ___ \| |_| |___) |_____| |_) |
      \__\            /_/   \_\____/|____/      |____/

Welcome to the ADS-B Docker Easy Install Script

EOM
}

function update_apt_repos() {
    logger "update_apt_repos" "Performing 'apt-get update'..." "$LIGHTBLUE"
    if apt-get update -y >> "$LOGFILE" 2>&1; then
        logger "update_apt_repos" "'apt-get update' was successful!" "$LIGHTGREEN"
    fi
}

function install_with_apt() {
    # $1 = package name
    logger "install_with_apt" "Installing package $1..." "$LIGHTBLUE"
    # Attempt download of docker script
    if apt-get install -y "$1" >> "$LOGFILE" 2>&1; then
        logger "install_with_apt" "Package $1 installed successfully!" "$LIGHTGREEN"
    else
        logger "install_with_apt" "ERROR: Could not install package $1 via apt-get :-(" "$LIGHTRED"
        exit_failure
    fi
}

function is_binary_installed() {
    # $1 = binary name
    # Check if bc is installed
    logger_logfile_only "is_binary_installed" "Checking if $1 is installed"
    if which "$1" >> "$LOGFILE" 2>&1; then
        # binary is already installed
        logger "is_binary_installed" "$1 is already installed!" "$LIGHTGREEN"
    else
        return 1
    fi
}

function update_docker() {

    # Check to see if docker requires an update
    logger_logfile_only "update_docker" "Checking to see if docker components require an update"
    if [[ "$(apt-get -u --just-print upgrade | grep -c docker-ce)" -gt "0" ]]; then
        logger_logfile_only "update_docker" "Docker components DO require an update"

        # Check if containers are running, if not, attempt to upgrade to latest version
        logger_logfile_only "update_docker" "Checking if containers are running"
        if [[ "$(docker ps -q)" -gt "0" ]]; then
            
            # Containers running, don't update
            logger "update_docker" "WARNING: Docker components require an update, but you have running containers. Not updating docker, you will need to do this manually." "$YELLOW"

        else

            # Containers not running, do update
            logger "update_docker" "Docker components require an update. Performing update..." "$LIGHTBLUE"
            if apt-get upgrade -y docker-ce >> "$LOGFILE" 2>&1; then

                # Docker upgraded OK!
                logger "update_docker" "Docker upgraded successfully!" "$LIGHTGREEN"

            else

                # Docker upgrade failed
                logger "update_docker" "ERROR: Problem updating docker :-(" "$LIGHTRED"
                exit_failure

            fi
        fi

    else
        logger "update_docker" "Docker components are up-to-date!" "$LIGHTGREEN"
    fi
}

function install_docker() {

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
}

function get_latest_docker_compose_version() {

    # get latest version of docker-compose
    logger "get_latest_docker_compose_version" "Querying for latest version of docker-compose..." "$LIGHTBLUE"

    # clone docker-compose repo
    logger_logfile_only "get_latest_docker_compose_version" "Attempting clone of docker-compose git repo"
    if git clone "$REPO_URL_DOCKER_COMPOSE" "$REPO_PATH_DOCKER_COMPOSE" >> "$LOGFILE" 2>&1; then
        # do nothing
        :
    else
        logger "get_latest_docker_compose_version" "ERROR: Problem getting latest docker-compose version :-(" "$LIGHTRED"
        exit_failure
    fi
    # get latest tag version from cloned repo
    logger_logfile_only "get_latest_docker_compose_version" "Attempting to get latest tag from cloned docker-compose git repo"
    pushd "$REPO_PATH_DOCKER_COMPOSE" >> "$LOGFILE" 2>&1 || exit_failure
    if docker_compose_version_latest=$(git tag --sort="-creatordate" | head -1); then
        # do nothing
        :
    else
        logger "get_latest_docker_compose_version" "ERROR: Problem getting latest docker-compose version :-(" "$LIGHTRED"
        exit_failure
    fi
    popd >> "$LOGFILE" 2>&1 || exit_failure
    # clean up temp downloaded docker_compose repo
    rm -r "$REPO_PATH_DOCKER_COMPOSE"

    export docker_compose_version_latest

}

function update_docker_compose() {
    local docker_compose_version

    # docker_compose is already installed
    logger_logfile_only "update_docker_compose" "docker-compose is already installed, attempting to get version information:"
    if docker-compose version >> "$LOGFILE" 2>&1; then
        # do nothing
        :
    else
        logger "update_docker_compose" "ERROR: Problem getting docker-compose version :-(" "$LIGHTRED"
        exit_failure
    fi
    docker_compose_version=$(docker-compose version | grep docker-compose | cut -d ',' -f 1 | rev | cut -d ' ' -f 1 | rev)

    # check version of docker-compose vs latest
    logger_logfile_only "update_docker_compose" "Checking version of installed docker-compose vs latest docker-compose"
    if [[ "$docker_compose_version" == "$docker_compose_version_latest" ]]; then
        logger "update_docker_compose" "docker-compose is the latest version!" "$LIGHTGREEN"
    else

        # remove old versions of docker-compose
        logger "update_docker_compose" "Attempting to remove previous outdated versions of docker-compose..." "$YELLOW"
        while which docker-compose >> "$LOGFILE" 2>&1; do

            # if docker-compose was installed via apt-get
            if [[ $(dpkg --list | grep -c docker-compose) -gt "0" ]]; then
                logger_logfile_only "update_docker_compose" "Attempting 'apt-get remove -y docker-compose'..."
                if apt-get remove -y docker-compose >> "$LOGFILE" 2>&1; then
                    # do nothing
                    :
                else
                    logger "update_docker_compose" "ERROR: Problem uninstalling outdated docker-compose :-(" "$LIGHTRED"
                    exit_failure
                fi
            elif which pip >> "$LOGFILE" 2>&1; then
                if [[ $(pip list | grep -c docker-compose) -gt "0" ]]; then
                    logger_logfile_only "update_docker_compose" "Attempting 'pip uninstall -y docker-compose'..."
                    if pip uninstall -y docker-compose >> "$LOGFILE" 2>&1; then
                        # do nothing
                        :
                    else
                        logger "update_docker_compose" "ERROR: Problem uninstalling outdated docker-compose :-(" "$LIGHTRED"
                        exit_failure
                    fi
                fi
            elif [[ -f "/usr/local/bin/docker-compose" ]]; then
                logger_logfile_only "update_docker_compose" "Attempting 'mv /usr/local/bin/docker-compose /usr/local/bin/docker-compose.oldversion'..."
                if mv -v "/usr/local/bin/docker-compose" "/usr/local/bin/docker-compose.oldversion.$(date +%s)" >> "$LOGFILE" 2>&1; then
                    # do nothing
                    :
                else
                    logger "update_docker_compose" "ERROR: Problem uninstalling outdated docker-compose :-(" "$LIGHTRED"
                    exit_failure
                fi
            else
                logger_logfile_only "update_docker_compose" "Unsupported docker-compose installation method detected."
                logger "update_docker_compose" "ERROR: Problem uninstalling outdated docker-compose :-(" "$LIGHTRED"
                exit_failure
            fi
        done

        # Install current version of docker-compose as a container
        logger "update_docker_compose" "Installing docker-compose..." "$LIGHTBLUE"
        logger_logfile_only "update_docker_compose" "Attempting download of latest docker-compose container wrapper script"
        if curl -L --fail "https://github.com/docker/compose/releases/download/$docker_compose_version_latest/run.sh" -o /usr/local/bin/docker-compose >> "$LOGFILE" 2>&1; then
            logger_logfile_only "update_docker_compose" "Download of latest docker-compose container wrapper script was OK"

            # Make executable
            logger_logfile_only "update_docker_compose" "Attempting 'chmod a+x /usr/local/bin/docker-compose'..."
            if chmod -v a+x /usr/local/bin/docker-compose >> "$LOGFILE" 2>&1; then
                logger_logfile_only "update_docker_compose" "'chmod a+x /usr/local/bin/docker-compose' was successful"

                # Make sure we can now run docker-compose and it is the latest version
                docker_compose_version=$(docker-compose version | grep docker-compose | cut -d ',' -f 1 | rev | cut -d ' ' -f 1 | rev)
                if [[ "$docker_compose_version" == "$docker_compose_version_latest" ]]; then
                    logger "update_docker_compose" "docker-compose installed successfully!" "$LIGHTGREEN"
                else
                    logger "update_docker_compose" "ERROR: Issue running newly installed docker-compose :-(" "$LIGHTRED"
                    exit_failure
                fi
            else
                logger "update_docker_compose" "ERROR: Problem chmodding docker-compose container wrapper script :-(" "$LIGHTRED"
                exit_failure
            fi
        else
            logger "update_docker_compose" "ERROR: Problem downloading docker-compose container wrapper script :-(" "$LIGHTRED"
            exit_failure
        fi
    fi
}

function install_docker_compose() {

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
            if docker-compose version >> "$LOGFILE" 2>&1; then
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
}

function input_yes_or_no() {
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

function input_lat_long() {
    # Get lat/long input from user
    # $1 = previous lat (optional)
    # $2 = previous long (optional)
    # -----------------    
    local valid_input
    valid_input=0
    while [[ "$valid_input" -ne 1 ]]; do
        echo -ne "${LIGHTGRAY}Please enter your feeder's latitude (to 5 decimal places): "
        if [[ -n "$1" ]]; then
            echo -n "(previously: $1) "
        fi
        echo -ne "${NOCOLOR}"
        read -r USER_OUTPUT
        echo ""
        if echo "$USER_OUTPUT" | grep -P '^-{0,1}\d{1,3}\.\d{3,5}$' > /dev/null 2>&1; then
            valid_input=1
        else
            echo -e "${YELLOW}Please enter a valid latitude!${NOCOLOR}"
        fi
    done
    echo "FEEDER_LAT=$USER_OUTPUT" >> "$PREFSFILE"
    valid_input=0
    while [[ "$valid_input" -ne 1 ]]; do
        echo -ne "${LIGHTGRAY}Please enter your feeder's longitude (to 5 decimal places): "
        if [[ -n "$2" ]]; then
            echo -n "(previously: $2) "
        fi
        echo -ne "${NOCOLOR}"
        read -r USER_OUTPUT
        echo ""
        if echo "$USER_OUTPUT" | grep -P '^-{0,1}\d{1,3}\.\d{3,5}$' > /dev/null 2>&1; then
            valid_input=1
        else
            echo -e "${YELLOW}Please enter a valid longitude!${NOCOLOR}"
        fi
    done
    echo "FEEDER_LONG=$USER_OUTPUT" >> "$PREFSFILE"
}

function input_altitude() {
    # Get altitude input from user
    # $1 = previous alt m (optional)
    # $2 = previous alt ft (optional)
    # -----------------    
    local valid_input
    valid_input=0
    while [[ "$valid_input" -ne 1 ]]; do
        echo -ne "${LIGHTGRAY}Please enter your feeder's altitude, suffixed with either 'm' for metres or 'ft' for feet: "
        if [[ -n "$1" ]]; then
            if [[ -n "$2" ]]; then
                echo -n "(previously: ${1}m / ${2}ft) "
            fi
        fi
        echo -ne "${NOCOLOR}"
        read -r USER_OUTPUT
        echo ""

        # if answer was given in m...
        if echo "$USER_OUTPUT" | grep -P '^\d+\.{0,1}\d*m$' > /dev/null 2>&1; then
            valid_input=1
            # convert m to ft
            bc_expression="scale=3; ${USER_OUTPUT%m} * 3.28084"
            alt_m="${USER_OUTPUT%m}"
            alt_ft="$(echo "$bc_expression" | bc -l)"

        # if answer was given in ft...
        elif echo "$USER_OUTPUT" | grep -P '^\d+\.{0,1}\d*ft$' > /dev/null 2>&1; then
            # convert ft to m
            valid_input=1
            bc_expression="scale=3; ${USER_OUTPUT%ft} * 0.3048"
            alt_m="$(echo "$bc_expression" | bc -l)"
            alt_ft="${USER_OUTPUT%ft}"

        # if wrong answer was given...
        else
            echo -e "${YELLOW}Please enter a valid altitude!${NOCOLOR}"
        fi
    done
    echo "FEEDER_ALT_M=$alt_m" >> "$PREFSFILE"
    echo "FEEDER_ALT_FT=$alt_ft" >> "$PREFSFILE"
}

function input_adsbx_details() {
    # Get adsbx input from user
    # $1 = previous uuid (optional)
    # $2 = previous sitename (optional)
    # -----------------    
    local valid_input
    valid_input=0
    while [[ "$valid_input" -ne 1 ]]; do
        echo -ne "  - ${LIGHTGRAY}Please enter your ADSB Exchange UUID. If you don't have one, just hit enter and a new UUID will be generated: "
        if [[ -n "$1" ]]; then
            if [[ -n "$2" ]]; then
                echo -n "(previously: ${1}) "
            fi
        fi
        echo -ne "${NOCOLOR}"
        read -r USER_OUTPUT
        echo ""

        if [[ -z "$USER_OUTPUT" ]]; then
            logger "input_adsbx_details" "Generating new ADSB Exchange UUID..." "$LIGHTBLUE"
            if adsbx_uuid=$(docker run --rm -it --entrypoint uuidgen mikenye/adsbexchange -t 2>/dev/null); then
                logger "input_adsbx_details" "New ADSB Exchange UUID generated OK: $adsbx_uuid" "$LIGHTBLUE"
                echo ""
                valid_input=1
            else
                logger "input_adsbx_details" "ERROR: Problem generating new ADSB Exchange UUID :-(" "$LIGHTRED"
                exit_failure
            fi
        else
            adsbx_uuid="$USER_OUTPUT"
            valid_input=1
        fi
    done

    valid_input=0
    while [[ "$valid_input" -ne 1 ]]; do
        echo -ne "  - ${LIGHTGRAY}Please enter a unique name for the ADSB Exchange feeder: "
        if [[ -n "$1" ]]; then
            if [[ -n "$2" ]]; then
                echo -n "(previously: ${2}) "
            fi
        fi
        echo -ne "${NOCOLOR}"
        read -r USER_OUTPUT
        echo ""

        NOSPACENAME="$(echo -n -e "${USER_OUTPUT}" | tr -c '[a-zA-Z0-9]_\- ' '_')"
        adsbx_sitename="${NOSPACENAME}_$((RANDOM % 90 + 10))"
        logger "input_adsbx_details" "Your ADSB Exchange site name will be set to: $adsbx_sitename" "$LIGHTBLUE"
        echo ""
        valid_input=1
    done

    echo "ADSBX_UUID=$adsbx_uuid" >> "$PREFSFILE"
    echo "ADSBX_SITENAME=$adsbx_sitename" >> "$PREFSFILE"
}

function input_fr24_details() {
    # Get fr24 input from user
    # $1 = previous fr24key (optional)
    # $2 = previous fr24_email
    # -----------------    
    local valid_input
    valid_input=0
    while [[ "$valid_input" -ne 1 ]]; do
        echo -ne "  - ${LIGHTGRAY}Please enter your Flightradar24 key. If you don't have one, just hit enter and you will be taken through the sign-up process: "
        if [[ -n "$1" ]]; then
            echo -n "(previously: ${1}) "
        fi
        echo -ne "${NOCOLOR}"
        read -r USER_OUTPUT
        echo ""

        # need to run sign up process
        if [[ -z "$USER_OUTPUT" ]]; then
            
            # get email
            echo -ne "  - ${LIGHTGRAY}Please enter a valid email address for your Flightradar24 account: "
            if [[ -n "$2" ]]; then
                echo -n "(previously: ${2}) "
            fi
            echo -ne "${NOCOLOR}"
            read -r FR24_EMAIL
            echo ""
            echo "FR24_EMAIL=$FR24_EMAIL" >> "$PREFSFILE"
            
            # run through sign-up process
            # pull & start container
            logger "input_fr24_details" "Running flightradar24 sign-up process (takes up to 2 mins)..." "$LIGHTBLUE"
            docker pull mikenye/flightradar24 >> "$LOGFILE" 2>&1
            CONTAINER_ID_FR24=$(docker run -d --rm -it --entrypoint fr24feed mikenye/fr24feed --signup)
            # write out expect script to attach to container and issue commands
            write_fr24_expectscript "$CONTAINER_ID_FR24"
            # run expect script & interpret output
            logger_logfile_only "input_fr24_details" "Running expect script..."
            if expect "$FILE_FR24SIGNUP_EXPECT" >> "$FILE_FR24SIGNUP_LOG" 2>&1; then
                logger_logfile_only "input_fr24_details" "Expect script finished OK"
                valid_input=1
            else
                logger "input_fr24_details" "ERROR: Problem running flightradar24 sign-up process :-(" "$LIGHTRED"
                docker logs "$CONTAINER_ID_FR24" >> "$LOGFILE"
                valid_input=0
                docker kill "$CONTAINER_ID_FR24" > /dev/null 2>&1 || true
                exit_failure
            fi

            docker logs "$CONTAINER_ID_FR24" > "$FILE_FR24SIGNUP_LOG"
            docker kill "$CONTAINER_ID_FR24" > /dev/null 2>&1 || true
            
            # try to get sharing key
            regex_sharing_key='^\+ Your sharing key \((\w+)\) has been configured and emailed to you for backup purposes\.'
            if grep -P "$regex_sharing_key" "$FILE_FR24SIGNUP_LOG" >> "$LOGFILE" 2>&1; then
                sharing_key=$(grep -P "$regex_sharing_key" "$FILE_FR24SIGNUP_LOG" | \
                sed -r "s/$regex_sharing_key/\1/")
                echo "FR24_KEY=$sharing_key" >> "$PREFSFILE"
                logger "input_fr24_details" "Your new flightradar24 sharing key is: $sharing_key" "$LIGHTGREEN"
                valid_input=1
            else
                logger "input_fr24_details" "ERROR: Could not find flightradar24 sharing key :-(" "$LIGHTRED"
                cat "$FILE_FR24SIGNUP_LOG" >> "$LOGFILE"
                valid_input=0
                exit_failure
            fi

            # try to get radar ID
            regex_radar_id='^\+ Your radar id is ([A-Za-z0-9\-]+), please include it in all email communication with us\.'
            if grep -P "$regex_radar_id" "$FILE_FR24SIGNUP_LOG" >> "$LOGFILE" 2>&1; then
                radar_id=$(grep -P "$regex_radar_id" "$FILE_FR24SIGNUP_LOG" | \
                sed -r "s/$regex_radar_id/\1/")
                echo "FR24_RADAR_ID=$radar_id" >> "$PREFSFILE"
                logger "input_fr24_details" "Your new flightradar24 radar ID is: $radar_id" "$LIGHTGREEN"
                valid_input=1
            else
                logger "input_fr24_details" "ERROR: Could not find flightradar24 radar ID :-(" "$LIGHTRED"
                cat "$FILE_FR24SIGNUP_LOG" >> "$LOGFILE"
                valid_input=0
                exit_failure
            fi

        else
            valid_input=1
        fi
    done
}

function input_piaware_details() {
    # Get piaware input from user
    # $1 = previous feeder id (optional)
    # -----------------    
    local valid_input
    valid_input=0
    while [[ "$valid_input" -ne 1 ]]; do
        echo -ne "  - ${LIGHTGRAY}Please enter your FlightAware feeder ID. If you don't have one, just hit enter and a new one will be generated: "
        if [[ -n "$1" ]]; then
            echo -n "(previously: ${1}) "
        fi
        echo -ne "${NOCOLOR}"
        read -r USER_OUTPUT
        echo ""

        # need to generate a new feeder id
        if [[ -z "$USER_OUTPUT" ]]; then
            
            # run through sign-up process
            logger "input_piaware_details" "Running piaware feeder-id generation process (takes approx. 30 seconds)..." "$LIGHTBLUE"
            docker pull mikenye/piaware >> "$LOGFILE" 2>&1
            source "$PREFSFILE"
            CONTAINER_ID_PIAWARE=$(docker run \
                -d \
                --rm \
                -it \
                -e BEASTHOST=127.0.0.99 \
                -e LAT="$FEEDER_LAT" \
                -e LONG="$FEEDER_LONG" \
                mikenye/piaware)
            
            # run expect script (to wait until logged in and a feeder ID is generated)
            write_piaware_expectscript "$CONTAINER_ID_PIAWARE"
            if expect "$FILE_PIAWARESIGNUP_EXPECT" >> "$LOGFILE" 2>&1; then
                logger_logfile_only "input_piaware_details" "Expect script finished OK"
                valid_input=1
            else
                logger "input_piaware_details" "ERROR: Problem running piaware feeder-id generation process :-(" "$LIGHTRED"
                docker logs "$CONTAINER_ID_PIAWARE" >> "$LOGFILE"
                valid_input=0
                docker kill "$CONTAINER_ID_PIAWARE" > /dev/null 2>&1 || true
                exit_failure
            fi

            docker logs "$CONTAINER_ID_PIAWARE" > "$FILE_PIAWARESIGNUP_LOG"
            docker kill "$CONTAINER_ID_PIAWARE" > /dev/null 2>&1 || true
            
            # try to retrieve the feeder ID from the container log
            if grep -oP 'my feeder ID is \K[a-f0-9\-]+' "$FILE_PIAWARESIGNUP_LOG" > /dev/null 2>&1; then
                piaware_feeder_id=$(grep -oP 'my feeder ID is \K[a-f0-9\-]+' "$FILE_PIAWARESIGNUP_LOG")
                echo "PIAWARE_FEEDER_ID=$piaware_feeder_id" >> "$PREFSFILE"
                logger "input_piaware_details" "Your new piaware feeder-id is: $piaware_feeder_id" "$LIGHTGREEN"
                valid_input=1
            else
                logger "input_piaware_details" "ERROR: Could not find piaware feeder-id :-(" "$LIGHTRED"
                cat "$FILE_PIAWARESIGNUP_LOG" >> "$LOGFILE"
                exit_failure
            fi
        else
            valid_input=1
        fi
    done
}

function input_opensky_details() {
    # Get opensky input from user
    # $1 = previous opensky username (optional)
    # -----------------    
    local valid_input

    # Let the user know that they should go and register for an account at OpenSky
    echo -e "  - ${LIGHTGRAY}Please ensure you have registered for an account on the OpenSky Network website,"
    echo -e "    (https://opensky-network.org/). You will need your OpenSky Network username in the next step."
    echo -ne "   Press any key to continue${NOCOLOR}"
    read -rsn1

    valid_input=0
    while [[ "$valid_input" -ne 1 ]]; do
        echo -ne "  - ${LIGHTGRAY}Please enter your OpenSky Network username: "
        if [[ -n "$1" ]]; then
            echo -n "(previously: ${1}) "
        fi
        echo -ne "${NOCOLOR}"
        read -r USER_OUTPUT
        echo ""
        if echo "$USER_OUTPUT" | grep -P '^.+$' > /dev/null 2>&1; then
            valid_input=1
        else
            echo -e "${YELLOW}Please enter a valid OpenSky Network username!${NOCOLOR}"
        fi
    done
    echo "OPENSKY_USERNAME=$USER_OUTPUT" >> "$PREFSFILE"
    
}

function find_rtlsdr_devices() {

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

    # Feeder position
    echo " * Feeder latitude is: $FEEDER_LAT"
    echo " * Feeder longitude is: $FEEDER_LONG"
    echo " * Feeder altitude is: ${FEEDER_ALT_M}m / ${FEEDER_ALT_FT}ft"

    # ADSBx
    if [[ "$FEED_ADSBX" == "y" ]]; then
        echo " * ADSB-Exchange docker container will be created and configured"
        echo "     - UUID: $ADSBX_UUID"
        echo "     - Site name: $ADSBX_SITENAME"
    else
        echo " * No feeding to ADSB-Exchange"
    fi

    # FR24
    if [[ "$FEED_FLIGHTRADAR24" == "y" ]]; then
        echo " * Flightradar24 docker container will be created and configured"
        echo "     - Sharing Key: $FR24_KEY"
        echo "     - Site name: $FR24_RADAR_ID"
    else
        echo " * No feeding to Flightradar24"
    fi

    # Opensky
    if [[ "$FEED_OPENSKY" == "y" ]]; then
        echo " * OpenSky Network docker container will be created and configured"
        echo "     - OpenSky Network Username: $OPENSKY_USERNAME"
    else
        echo " * No feeding to OpenSky Network"
    fi

    # FlightAware
    if [[ "$FEED_FLIGHTAWARE" == "y" ]]; then
        echo " * FlightAware (piaware) docker container will be created and configured"
        echo "     - Piaware Feeder ID: $PIAWARE_FEEDER_ID"
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

function get_rtlsdr_preferences() {
    echo ""
    echo -e "${WHITE}===== RTL-SDR Preferences =====${NOCOLOR}"
    echo ""
    if input_yes_or_no "Do you wish to use an RTL-SDR device attached to this machine to receive ADS-B ES (1090MHz) traffic?"; then

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

        # TODO if radios already have 00001090 and 00000978 serials, then
        #   - let user know radios already have serials set
        #   - assume 00001090 and 00000978 are for ADS-B and 
        # Example wording:
        #   "Found RTL-SDR with serial number '00001090'. Will assume this device should be used for ADS-B ES (1090MHz) reception."
        #   "Found RTL-SDR with serial number '00000978'. Will assume this device should be used for ADS-B UAT (978MHz) reception."
        # press any key to continue

        logger "TODO!" "NEED TO DO RTL-SDR SERIAL STUFF!!!"

        # only_one_radio_attached=0
        # while [[ "$only_one_radio_attached" -eq 0 ]]; do

        #     # Ask the user to unplug all but one RTL-SDR
        #     echo ""
        #     echo -e "${YELLOW}Please ensure the only RTL-SDR device connected to this machine is the one to be used for ADS-B ES (1090MHz) reception!${NOCOLOR}"
        #     echo -e "${YELLOW}Disconnect all other RTL-SDR devices!${NOCOLOR}"
        #     read -p "Press any key to continue" -sn1
        #     echo ""

        #     # Look for RTL-SDR radios
        #     find_rtlsdr_devices
        #     echo -n "Found ${#RTLSDR_DEVICES[@]} "
        #     if [[ "${#RTLSDR_DEVICES[@]}" -gt 1 ]]; then
        #         echo "radios."
        #     elif [[ "${#RTLSDR_DEVICES[@]}" -eq 0 ]]; then
        #         echo "radios."
        #     else
        #         echo "radio."
        #     fi

        #     # If more than one radio is detected, then ask the user to unplug all other radios except the one they wish to use for ADSB 1090MHz reception.
        #     if [[ "${#RTLSDR_DEVICES[@]}" -gt 1 ]]; then
        #         echo ""
        #         logger "get_preferences" "More than one RTL-SDR device was found. Please un-plug all RTL-SDR devices, except the device you wish to use for ADS-B ES (1090MHz) reception." "$LIGHTRED"
        #         echo ""
        #     elif [[ "${#RTLSDR_DEVICES[@]}" -eq 1 ]]; then
        #         only_one_radio_attached=1
        #     else
        #         logger "get_preferences" "No RTL-SDR devices found. Please connect the RTL-SDR device that will be used for ADS-B ES (1090MHz) reception."
        #     fi
        # done

        # # If only one radio present, check serial. If not 00001090 then change to this
        # RTLSDR_ADSB_

    fi
}

function get_feeder_preferences() {
    echo ""
    echo -e "${WHITE}===== Feeder Preferences =====${NOCOLOR}"
    echo ""
    # Delete prefs file if it exists
    rm "$PREFSFILE" > /dev/null 2>&1 || true
    touch "$PREFSFILE"

    # Get feeder lat/long
    input_lat_long "$FEEDER_LAT" "$FEEDER_LONG"

    # Get feeder alt
    input_altitude "$FEEDER_ALT_M" "$FEEDER_ALT_FT"


    if input_yes_or_no "Do you want to feed ADS-B Exchange (adsbexchange.com)?" "$FEED_ADSBX"; then
        echo "FEED_ADSBX=\"y\"" >> "$PREFSFILE"
        input_adsbx_details "$ADSBX_UUID" "$ADSBX_SITENAME"
    else
        {
            echo "FEED_ADSBX=\"n\""
            echo "ADSBX_UUID="
            echo "ADSBX_SITENAME="
        } >> "$PREFSFILE"
    fi
    if input_yes_or_no "Do you want to feed Flightradar24 (flightradar24.com)?" "$FEED_FLIGHTRADAR24"; then
        echo "FEED_FLIGHTRADAR24=\"y\"" >> "$PREFSFILE"
        input_fr24_details "$FR24_KEY" "$FR24_EMAIL"
    else
        {
            echo "FEED_FLIGHTRADAR24=\"n\""
            echo "FR24_EMAIL="
            echo "FR24_KEY="
            echo "FR24_RADAR_ID="
        } >> "$PREFSFILE"
    fi
    if input_yes_or_no "Do you want to feed OpenSky Network (opensky-network.org)?" "$FEED_OPENSKY"; then
        echo "FEED_OPENSKY=\"y\"" >> "$PREFSFILE"
        input_opensky_details "$OPENSKY_USERNAME"
    else
        {
            echo "FEED_OPENSKY=\"n\""
            echo "OPENSKY_USERNAME="
        } >> "$PREFSFILE"
    fi
    if input_yes_or_no "Do you want to feed FlightAware (flightaware.com)?" "$FEED_FLIGHTAWARE"; then
        echo "FEED_FLIGHTAWARE=\"y\"" >> "$PREFSFILE"
        input_piaware_details "$PIAWARE_FEEDER_ID"
    else
        {
            echo "FEED_FLIGHTAWARE=\"n\""
            echo "PIAWARE_FEEDER_ID="
        } >> "$PREFSFILE"
    fi
    if input_yes_or_no "Do you want to feed PlaneFinder (planefinder.net)?" "$FEED_PLANEFINDER"; then
        echo "FEED_PLANEFINDER=\"y\"" >> "$PREFSFILE"
    else
        echo "FEED_PLANEFINDER=\"n\"" >> "$PREFSFILE"
    fi
    if input_yes_or_no "Do you want to feed AirNav RadarBox (radarbox.com)?" "$FEED_RADARBOX"; then
        echo "FEED_RADARBOX=\"y\"" >> "$PREFSFILE"
    else
        echo "FEED_RADARBOX=\"n\"" >> "$PREFSFILE"
    fi
    echo ""

    # TODO Extra cool stuff like:
    #   - ask about visualisations
    #       - readsb/tar1090/vrs/fam/skyaware/etc
    #   - get Bing Maps API key and add to flightaware etc

}

function unload_rtlsdr_kernel_modules() {
    echo ""
    echo -e "${WHITE}===== Kernel Modules =====${NOCOLOR}"
    echo ""
    for modulename in "${RTLSDR_MODULES_TO_BLACKLIST[@]}"; do
        if lsmod | grep -i "$modulename" > /dev/null 2>&1; then
            if input_yes_or_no "Module '$modulename' must be unloaded to continue. Is this OK?"; then
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
        else
            logger "unload_rtlsdr_kernel_modules" "Module '$modulename' is not loaded!" "$LIGHTGREEN"
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
rm "$LOGFILE" > /dev/null 2>&1 || true
logger_logfile_only "main" "Script started"
#shellcheck disable=SC2128,SC1102
command_line="$(printf %q "$BASH_SOURCE")$((($#)) && printf ' %q' "$@")"
logger_logfile_only "main" "Full command line: $command_line"

# Make sure the script is being run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root! Try 'sudo $command_line'" 
   exit 1
fi

# Display welcome message
welcome_msg

# Ensure apt-get update has been run
update_apt_repos

# Get git to download list of supported rtl-sdr radios
if ! is_binary_installed git; then
    echo ""
    echo -e "${WHITE}===== Installing 'git' =====${NOCOLOR}"
    echo ""
    echo "This script needs to install the 'git' (a source code management util), which is used for:"
    echo " * Retrieving the supported list of RTL-SDR devices from the rtl-sdr repository"
    echo " * Cloning the 'docker-compose' repository to determine the latest version"
    echo ""
    if ! input_yes_or_no "May this script install the 'git' utility?"; then
        echo "Not proceeding."
        echo ""
        exit 1
    else
        install_with_apt git
    fi
    echo ""
fi

# Get bc to convert between metric/imperial
if ! is_binary_installed bc; then
    echo ""
    echo -e "${WHITE}===== Installing 'bc' =====${NOCOLOR}"
    echo ""
    echo "This script needs to install the 'bc' utility (a CLI calculator), which is used for:"
    echo " * Converting between metric and imperial measurements automatically"
    echo ""
    if ! input_yes_or_no "May this script install the 'bc' utility?"; then
        echo "Not proceeding."
        echo ""
        exit 1
    else
        install_with_apt bc
    fi
    echo ""
fi

# Get expect to automatically run through sign-up processes
if ! is_binary_installed expect; then
    echo ""
    echo -e "${WHITE}===== Installing 'expect' =====${NOCOLOR}"
    echo ""
    echo "This script needs to install the 'expect' utility, which is used for:"
    echo " * Automatically completing feeder sign-ups"
    echo ""
    if ! input_yes_or_no "May this script install the 'expect' utility?"; then
        echo "Not proceeding."
        echo ""
        exit 1
    else
        install_with_apt expect
    fi
    echo ""
fi

# Get expect to automatically run through sign-up processes
if ! is_binary_installed docker; then
    echo ""
    echo -e "${WHITE}===== Installing 'docker' =====${NOCOLOR}"
    echo ""
    echo "This script needs to install docker, which is used for:"
    echo " * Running the containers!"
    echo ""
    if ! input_yes_or_no "May this script install 'docker'?"; then
        echo "Not proceeding."
        echo ""
        exit 1
    else
        install_docker
    fi
    echo ""
else
    update_docker
fi

# Get expect to automatically run through sign-up processes
get_latest_docker_compose_version
if ! is_binary_installed docker-compose; then
    echo ""
    echo -e "${WHITE}===== Installing 'docker-compose' =====${NOCOLOR}"
    echo ""
    echo "This script needs to install docker-compose, which is used for:"
    echo " * Managing the containers!"
    echo ""
    if ! input_yes_or_no "May this script install 'docker-compose'?"; then
        echo "Not proceeding."
        echo ""
        exit 1
    else
        install_docker_compose
    fi
    echo ""
else
    update_docker_compose
fi

# Unload and blacklist rtlsdr kernel modules
unload_rtlsdr_kernel_modules

# Get/Set preferences
confirm_prefs=0
while [[ "$confirm_prefs" -eq "0" ]]; do
    if [[ -e "$PREFSFILE" ]]; then
        #shellcheck disable=SC1090
        source "$PREFSFILE"
        show_preferences
        if input_yes_or_no "Do you want to change these preferences?"; then
            get_rtlsdr_preferences
            get_feeder_preferences
        else
            break
        fi
    else
        get_rtlsdr_preferences
        get_feeder_preferences
    fi
done

# Final go-ahead
echo ""
echo -e "${WHITE}===== FINAL CONFIRMATION =====${NOCOLOR}"
echo ""
if ! input_yes_or_no "Are you sure you want to proceed?"; then
    echo "Not proceeding."
    echo ""
    exit 1
fi
echo ""
echo ""
