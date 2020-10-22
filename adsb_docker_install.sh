#!/usr/bin/env bash
# shellcheck disable=SC2028,SC1090,SC2016

# Disabled shellcheck check notes:
#   - SC1090: Can't follow non-constant source. Use a directive to specify location.
#       - There are files that are sourced that don't yet exist until runtime.
#   - SC2028: Echo may not expand escape sequences. Use printf.
#       - The way we write out the FR24 / Piaware expect script logs a tonne of these.
#       - We don't want the escape sequences expanded in this instance.
#       - There's probably a better way to write out the expect script (heredoc?)
#   - SC2016: Expressions don't expand in single quotes, use double quotes for that.
#       - This is by design when we're making the docker-compose.yml file

# TODOs
#  - support local RTLSDR
#  - support feeding from radarcape (need to update adsbx image)
#  - if compose file exists, use yq (in helper container) to modify the file in place - this prevents clobbering user customisations
#  - any inline TODOs
#
#----------------------------------------------------------------------------

# Get PID of running instance of this script
export TOP_PID=$$

# Declar traps
trap cleanup EXIT
trap "exit 1" TERM

##### DEFINE GLOBALS #####

# Bash CLI Colors
NOCOLOR='\033[0m'
LIGHTRED='\033[1;31m'
LIGHTGREEN='\033[1;32m'
LIGHTBLUE='\033[1;34m'
WHITE='\033[1;37m'

# Version of this script's schema
CURRENT_SCHEMA_VERSION=1

# Regular Expressions
REGEX_PATTERN_OPENSKY_SERIAL=' Got a new serial number: \K[\-\d]+'
REGEX_PATTERN_RBFEEDER_KEY='Your new key is \K[a-f0-9]+\.'
REGEX_PATTERN_RTLSDR_RULES_IDVENDOR='ATTRS\{idVendor\}=="\K[0-9a-f]{4}'
REGEX_PATTERN_RTLSDR_RULES_IDPRODUCT='ATTRS\{idProduct\}=="\K[0-9a-f]{4}'
REGEX_PATTERN_LSUSB_BUSNUMBER='^Bus \K\d{3}'
REGEX_PATTERN_LSUSB_DEVICENUMBER='^Bus \d{3} Device \K\d{3}'
REGEX_PATTERN_VALID_LAT_LONG='^-{0,1}\d{1,3}\.\d{3,5}$'
REGEX_PATTERN_VALID_ALT_M='^\d+\.{0,1}\d*m$'
REGEX_PATTERN_VALID_ALT_FT='^\d+\.{0,1}\d*ft$'
REGEX_PATTERN_FR24_SHARING_KEY='^\+ Your sharing key \((\w+)\) has been configured and emailed to you for backup purposes\.'
REGEX_PATTERN_FR24_RADAR_ID='^\+ Your radar id is ([A-Za-z0-9\-]+), please include it in all email communication with us\.'
REGEX_PATTERN_PIAWARE_FEEDER_ID='my feeder ID is \K[a-f0-9\-]+'
REGEX_PATTERN_NOT_EMPTY='^.+$'
REGEX_PATTERN_COMPOSEFILE_SCHEMA_HEADER='^\s*#\s*ADSB_DOCKER_INSTALL_ENVFILE_SCHEMA=\K\d+\s*$'
REGEX_PATTERN_VALID_ADSBX_SITENAME='_\d+$'
REGEX_PATTERN_VALID_EMAIL_ADDRESS='^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$'
REGEX_PATTERN_COMMENTS='^\s*#'

# File/dir locations
LOGFILE="/tmp/adsb_docker_install.$(date -Iseconds).log"

# Whiptail dialog globals
WHIPTAIL_BACKTITLE="ADS-B Docker Easy Install"

# Temp files - created in one dir
TMPDIR_ADSB_DOCKER_INSTALL="$(mktemp -d --suffix=.adsb_docker_install.TMPDIR_ADSB_DOCKER_INSTALL)"
TMPFILE_FR24SIGNUP_EXPECT="$TMPDIR_ADSB_DOCKER_INSTALL/TMPFILE_FR24SIGNUP_EXPECT"
TMPFILE_FR24SIGNUP_LOG="$TMPDIR_ADSB_DOCKER_INSTALL/TMPFILE_FR24SIGNUP_LOG"
TMPFILE_PIAWARESIGNUP_EXPECT="$TMPDIR_ADSB_DOCKER_INSTALL/TMPFILE_PIAWARESIGNUP_EXPECT"
TMPFILE_PIAWARESIGNUP_LOG="$TMPDIR_ADSB_DOCKER_INSTALL/TMPFILE_PIAWARESIGNUP_LOG"
TMPFILE_RBFEEDERSIGNUP_EXPECT="$TMPDIR_ADSB_DOCKER_INSTALL/TMPFILE_RBFEEDERSIGNUP_EXPECT"
TMPFILE_RBFEEDERSIGNUP_LOG="$TMPDIR_ADSB_DOCKER_INSTALL/TMPFILE_RBFEEDERSIGNUP_LOG"
TMPFILE_OPENSKYSIGNUP_EXPECT="$TMPDIR_ADSB_DOCKER_INSTALL/TMPFILE_OPENSKYSIGNUP_EXPECT"
TMPFILE_OPENSKYSIGNUP_LOG="$TMPDIR_ADSB_DOCKER_INSTALL/TMPFILE_OPENSKYSIGNUP_LOG"
TMPFILE_DOCKER_COMPOSE_SCRATCH="$TMPDIR_ADSB_DOCKER_INSTALL/TMPFILE_DOCKER_COMPOSE_SCRATCH"
# TMPFILE_NEWPREFS will be defined later
TMPFILE_NEWPREFS=

# Temp dirs - created in above main temp dir
TMPDIR_REPO_DOCKER_COMPOSE="$TMPDIR_ADSB_DOCKER_INSTALL/TMPDIR_REPO_DOCKER_COMPOSE"
mkdir -p "$TMPDIR_REPO_DOCKER_COMPOSE"
TMPDIR_REPO_RTLSDR="$TMPDIR_ADSB_DOCKER_INSTALL/TMPDIR_REPO_RTLSDR"
mkdir -p "$TMPDIR_ADSB_DOCKER_INSTALL"
TMPDIR_RBFEEDER_FAKETHERMAL="$TMPDIR_ADSB_DOCKER_INSTALL/TMPDIR_RBFEEDER_FAKETHERMAL"
mkdir -p "$TMPDIR_ADSB_DOCKER_INSTALL"

# Temp container IDs
CONTAINER_ID_FR24=
CONTAINER_ID_PIAWARE=
CONTAINER_ID_RBFEEDER=
CONTAINER_ID_OPENSKY=
CONTAINER_ID_TEMPORARY=
# NOTE: If more temp containers are made, add to cleanup function below
# NOTE: Also make sure they are started with '--rm' so they're deleted when killed

# Container Images
IMAGE_TEMPORARY_HELPER="mikenye/adsb_docker_install_helper:latest"
IMAGE_DOCKER_COMPOSE="linuxserver/docker-compose:latest"

# URLs
URL_REPO_RTLSDR="git://git.osmocom.org/rtl-sdr"
URL_PLANEFINDER_REGISTRATION="http://dataupload.planefinder.net/ng-client/auth.php"

# List of RTL-SRD devices (will be populated by script)
RTLSDR_DEVICES=()

# List of kernel modules to blacklist on the host
RTLSDR_MODULES_TO_BLACKLIST=()
RTLSDR_MODULES_TO_BLACKLIST+=(rtl2832_sdr)
RTLSDR_MODULES_TO_BLACKLIST+=(dvb_usb_rtl28xxu)
RTLSDR_MODULES_TO_BLACKLIST+=(rtl2832)

# Default settings for .env file
ADSBX_SITENAME=
ADSBX_UUID=
BEASTHOST=
BEASTPORT=30005
DATASOURCE_TYPE=
FEED_ADSBX=
FEED_FLIGHTAWARE=
FEED_FLIGHTRADAR24=
FEED_OPENSKY=
FEED_PLANEFINDER=
FEED_RADARBOX=
FEEDER_ALT_FT=
FEEDER_ALT_M=
FEEDER_ALT=
FEEDER_LAT=
FEEDER_LONG=
FEEDER_TZ=
FR24_EMAIL=
FR24_KEY=
FR24_RADAR_ID=
OPENSKY_SERIAL=
OPENSKY_USERNAME=
PIAWARE_FEEDER_ID=
PLANEFINDER_EMAIL=
PLANEFINDER_SHARECODE=
RADARBOX_SHARING_KEY=
SBSHOST=
SBSPORT=30003

##### CLEAN-UP FUNCTION #####

# Cleanup function run on script exit (via trap)
function cleanup() {
    # NOTE: everything in this script should end with ' > /dev/null 2>&1 || true'
    #       this ensures any errors during cleanup are suppressed

    # Cleanup of temp files/dirs
    rm -r "$TMPDIR_ADSB_DOCKER_INSTALL" > /dev/null 2>&1 || true
    
    # Cleanup of temp containers
    docker kill "$CONTAINER_ID_FR24" > /dev/null 2>&1 || true
    docker kill "$CONTAINER_ID_PIAWARE" > /dev/null 2>&1 || true
    docker kill "$CONTAINER_ID_RBFEEDER" > /dev/null 2>&1 || true
    docker kill "$CONTAINER_ID_OPENSKY" > /dev/null 2>&1 || true
    docker kill "$CONTAINER_ID_TEMPORARY" > /dev/null 2>&1 || true
}


##### DEFINE FUNCTIONS #####

function is_X_in_list_Y() {
    local list="$2"
    local item="$1"
    if [[ "$list" =~ (^|[[:space:]])"$item"($|[[:space:]]) ]] ; then
        # yes, list include item
        result=0
    else
        result=1
    fi
    return $result
}

function logger() {
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

function exit_user_cancelled() {
    echo ""
    echo "Installation has been cancelled. A log file containing troubleshooting information is located at:"
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
    source "$TMPFILE_NEWPREFS"
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
        # TODO - Add better error handlin
        # eg: Handle 'Validating email/location information...ERROR'
        # Need some real-world failure logs
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
    } > "$TMPFILE_FR24SIGNUP_EXPECT"
}

function write_piaware_expectscript() {
    # $1 = container ID of piaware signup container that's running
    #-----
    source "$TMPFILE_NEWPREFS"
    {
        echo '#!/usr/bin/env expect'
        echo 'set timeout 120'
        echo "spawn docker logs -f $1"
        echo 'expect " my feeder ID is "'
    } > "$TMPFILE_PIAWARESIGNUP_EXPECT"
}

function write_rbfeeder_expectscript() {
    # $1 = container ID of rbfeeder signup container that's running
    #-----
    source "$TMPFILE_NEWPREFS"
    {
        echo '#!/usr/bin/env expect'
        echo 'set timeout 120'
        echo "spawn docker logs -f $1"
        echo 'expect " Your new key is "'
    } > "$TMPFILE_RBFEEDERSIGNUP_EXPECT"
}

function write_opensky_expectscript() {
    # $1 = container ID of opensky signup container that's running
    #-----
    source "$TMPFILE_NEWPREFS"
    {
        echo '#!/usr/bin/env expect'
        echo 'set timeout 120'
        echo "spawn docker logs -f $1"
        echo 'expect " Got a new serial number: "'
    } > "$TMPFILE_OPENSKYSIGNUP_EXPECT"
}

function welcome_msg() {
    msg=$(cat << "EOM"
  __                  
  \  \     _ _            _    ____  ____        ____
   \**\ ___\/ \          / \  |  _ \/ ___|      | __ )
  X*#####*+^^\_\        / _ \ | | | \___ \ _____|  _ \
   o/\  \              / ___ \| |_| |___) |_____| |_) |
      \__\            /_/   \_\____/|____/      |____/

Welcome to the ADS-B Docker Easy Install Script! This will:

  1. Configure a source of ADS-B data (SDR or network)
  2. Install docker & docker-compose
  3. Prompt you for your feeder settings
  4. Create docker-compose.yml & .env files with your settings
  5. Deploy containers for feeding services you choose
     (and supporting containers)

Do you wish to continue?
EOM
)
    title="Welcome!"
    if whiptail \
        --backtitle "$WHIPTAIL_BACKTITLE" \
        --title "$title" \
        --yesno "$msg" \
        23 78; then
        :
        # user wants to proceed
    else
        exit_user_cancelled
    fi
}

function update_apt_repos() {
    logger "update_apt_repos" "Performing 'apt-get update'..."
    whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "Performing 'apt-get update'..." 8 78
    if apt-get update -y >> "$LOGFILE" 2>&1; then
        logger "update_apt_repos" "'apt-get update' was successful!"
    fi
}

function install_with_apt() {
    # $1 = package name
    logger "install_with_apt" "Installing package $1..."
    whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "Installing package '$1'..." 8 78
    # Attempt download of docker script
    if apt-get install -y "$1" >> "$LOGFILE" 2>&1; then
        logger "install_with_apt" "Package $1 installed successfully!"
    else
        logger "install_with_apt" "ERROR: Could not install package $1 via apt-get :-("
        NEWT_COLORS='root=,red' \
            whiptail \
                --title "Error" \
                --msgbox "Could not install package $1 via apt-get :-(" 8 78
        exit_failure
    fi
}

function is_binary_installed() {
    # $1 = binary name
    # Check if binary is installed
    whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "Checking if '$1' is installed..." 8 78
    logger "is_binary_installed" "Checking if $1 is installed"
    if which "$1" >> "$LOGFILE" 2>&1; then
        # binary is already installed
        logger "is_binary_installed" "$1 is already installed!"
    else
        return 1
    fi
}

function update_docker() {
    # Check to see if docker requires an update
    whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "Checking if docker components require an update..." 8 78
    logger "update_docker" "Checking to see if docker components require an update"
    if [[ "$(apt-get -u --just-print upgrade | grep -c docker-ce)" -gt "0" ]]; then
        whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "Docker components require an update..." 8 78
        logger "update_docker" "Docker components DO require an update"
        # Check if containers are running, if not, attempt to upgrade to latest version
        logger "update_docker" "Checking if containers are running"
        if [[ "$(docker ps -q)" -gt "0" ]]; then
            # Containers running, don't update
            logger "update_docker" "WARNING: Docker components require updating, but you have running containers. Not updating docker, you will need to do this manually."
            NEWT_COLORS='root=,yellow' \
                whiptail \
                    --backtitle "$WHIPTAIL_BACKTITLE" \
                    --title "Warning" \
                    --msgbox "Performing 'apt-get update'..." \
                    8 78

        else

            # Containers not running, do update
            logger "update_docker" "Docker components require an update. Performing update..."
            whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "Docker components require an update. Performing update..." 8 78
            if apt-get upgrade -y docker-ce >> "$LOGFILE" 2>&1; then

                # Docker upgraded OK!
                logger "update_docker" "Docker upgraded successfully!"
                whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "Docker upgraded successfully!" 8 78

            else

                # Docker upgrade failed
                logger "update_docker" "ERROR: Problem updating docker :-("
                NEWT_COLORS='root=,red' \
                whiptail \
                    --title "Error" \
                    --msgbox "Problem updating docker :-(" 8 78
                exit_failure

            fi
        fi

    else
        logger "update_docker" "Docker components are up-to-date!"
        whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "Docker components are up-to-date!" 8 78
    fi
}

function install_docker() {

    # Docker is not installed
    logger "install_docker" "Installing docker..."
    whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "Installing docker..." 8 78

    # Attempt download of docker script
    logger "install_docker" "Attempt download of get-docker.sh script"
    if curl -o /tmp/get-docker.sh -fsSL https://get.docker.com >> "$LOGFILE" 2>&1; then
        logger "install_docker" "get-docker.sh script downloaded OK"
    else
        logger "install_docker" "ERROR: Could not download get-docker.sh script from https://get.docker.com :-("
        NEWT_COLORS='root=,red' \
            whiptail \
                --title "Error" \
                --msgbox "Could not download get-docker.sh script from https://get.docker.com :-(" 8 78
        exit_failure
    fi

    # Attempt to run docker script
    logger "install_docker" "Attempt to run get-docker.sh script"
    if sh /tmp/get-docker.sh >> "$LOGFILE" 2>&1; then
        logger "install_docker" "Docker installed successfully!"
        whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "Docker installed successfully!" 8 78
    else
        logger "install_docker" "ERROR: Problem running get-docker.sh installation script :-("
        NEWT_COLORS='root=,red' \
            whiptail \
                --title "Error" \
                --msgbox "Problem running get-docker.sh installation script :-(" 8 78
        exit_failure
    fi
}

function get_latest_docker_compose_version() {

    # get latest version of docker-compose
    logger "get_latest_docker_compose_version" "Querying for latest version of docker-compose..."
    whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "Finding latest version of docker-compose..." 8 78

    if docker pull "$IMAGE_DOCKER_COMPOSE" >> "$LOGFILE" 2>&1; then
    :
    else
        NEWT_COLORS='root=,red' \
            whiptail \
                --title "Error" \
                --msgbox "Failed to pull (download) $IMAGE_DOCKER_COMPOSE :-(" 8 78
        exit_failure
    fi

    # get latest tag version from image
    logger "get_latest_docker_compose_version" "Attempting to get latest tag from cloned docker-compose git repo"
    if docker_compose_version_latest=$(docker run --rm -it "$IMAGE_DOCKER_COMPOSE" -version | cut -d ',' -f 1 | rev | cut -d ' ' -f 1 | rev); then
        # do nothing
        :
    else
        logger "get_latest_docker_compose_version" "ERROR: Problem getting latest docker-compose version :-("
        NEWT_COLORS='root=,red' \
            whiptail \
                --title "Error" \
                --msgbox "Problem getting latest docker-compose version :-(" 8 78
        exit_failure
    fi

    export docker_compose_version_latest

}

function update_docker_compose() {
    local docker_compose_version

    # docker_compose is already installed
    logger "update_docker_compose" "docker-compose is already installed, attempting to get version information:"
    whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "docker-compose is already installed, attempting to get version..." 8 78
    if docker-compose version >> "$LOGFILE" 2>&1; then
        # do nothing
        :
    else
        logger "update_docker_compose" "ERROR: Problem getting docker-compose version :-("
        NEWT_COLORS='root=,red' \
            whiptail \
                --title "Error" \
                --msgbox "Problem getting docker-compose version :-(" 8 78
        exit_failure
    fi
    docker_compose_version=$(docker-compose version | grep docker-compose | cut -d ',' -f 1 | rev | cut -d ' ' -f 1 | rev)

    # check version of docker-compose vs latest
    logger "update_docker_compose" "Checking version of installed docker-compose vs latest docker-compose"
    if [[ "$docker_compose_version" == "$docker_compose_version_latest" ]]; then
        logger "update_docker_compose" "docker-compose is the latest version!"
        whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "docker-compose is the latest version!" 8 78
    else

        # remove old versions of docker-compose
        logger "update_docker_compose" "Attempting to remove previous outdated versions of docker-compose..."
        whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "Attempting to remove previous outdated versions of docker-compose..." 8 78
        while which docker-compose >> "$LOGFILE" 2>&1; do

            # if docker-compose was installed via apt-get
            if [[ $(dpkg --list | grep -c docker-compose) -gt "0" ]]; then
                logger "update_docker_compose" "Attempting 'apt-get remove -y docker-compose'..."
                if apt-get remove -y docker-compose >> "$LOGFILE" 2>&1; then
                    # do nothing
                    :
                else
                    logger "update_docker_compose" "ERROR: Problem uninstalling outdated docker-compose :-("
                    NEWT_COLORS='root=,red' \
                    whiptail \
                        --title "Error" \
                        --msgbox "Problem uninstalling outdated docker-compose :-(" 8 78
                    exit_failure
                fi
            elif which pip >> "$LOGFILE" 2>&1; then
                if [[ $(pip list | grep -c docker-compose) -gt "0" ]]; then
                    logger "update_docker_compose" "Attempting 'pip uninstall -y docker-compose'..."
                    if pip uninstall -y docker-compose >> "$LOGFILE" 2>&1; then
                        # do nothing
                        :
                    else
                        logger "update_docker_compose" "ERROR: Problem uninstalling outdated docker-compose :-("
                        NEWT_COLORS='root=,red' \
                        whiptail \
                            --title "Error" \
                            --msgbox "Problem uninstalling outdated docker-compose :-(" 8 78
                        exit_failure
                    fi
                fi
            elif [[ -f "/usr/local/bin/docker-compose" ]]; then
                logger "update_docker_compose" "Attempting 'mv /usr/local/bin/docker-compose /usr/local/bin/docker-compose.oldversion'..."
                if mv -v "/usr/local/bin/docker-compose" "/usr/local/bin/docker-compose.oldversion.$(date +%s)" >> "$LOGFILE" 2>&1; then
                    # do nothing
                    :
                else
                    logger "update_docker_compose" "ERROR: Problem uninstalling outdated docker-compose :-("
                    NEWT_COLORS='root=,red' \
                    whiptail \
                        --title "Error" \
                        --msgbox "Problem uninstalling outdated docker-compose :-(" 8 78
                    exit_failure
                fi
            else
                logger "update_docker_compose" "Unsupported docker-compose installation method detected."
                NEWT_COLORS='root=,red' \
                    whiptail \
                        --title "Error" \
                        --msgbox "Problem uninstalling outdated docker-compose :-(" 8 78
                exit_failure
            fi
        done

        # Install current version of docker-compose as a container
        logger "update_docker_compose" "Installing docker-compose..."
        logger "update_docker_compose" "Attempting download of latest docker-compose container wrapper script"
        whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "Attempting installation of docker-compose container wrapper..." 8 78

        # TODO - Change to official installer once it supports multi-arch
        # see: https://github.com/docker/compose/issues/6831
        #URL_DOCKER_COMPOSE_INSTALLER="https://github.com/docker/compose/releases/download/$docker_compose_version_latest/run.sh"
        URL_DOCKER_COMPOSE_INSTALLER="https://raw.githubusercontent.com/linuxserver/docker-docker-compose/master/run.sh"
        
        if curl -L --fail "$URL_DOCKER_COMPOSE_INSTALLER" -o /usr/local/bin/docker-compose >> "$LOGFILE" 2>&1; then
            logger "update_docker_compose" "Download of latest docker-compose container wrapper script was OK"

            # Make executable
            logger "update_docker_compose" "Attempting 'chmod a+x /usr/local/bin/docker-compose'..."
            if chmod -v a+x /usr/local/bin/docker-compose >> "$LOGFILE" 2>&1; then
                logger "update_docker_compose" "'chmod a+x /usr/local/bin/docker-compose' was successful"

                # Make sure we can now run docker-compose and it is the latest version
                docker_compose_version=$(docker-compose version | grep docker-compose | cut -d ',' -f 1 | rev | cut -d ' ' -f 1 | rev)
                if [[ "$docker_compose_version" == "$docker_compose_version_latest" ]]; then
                    logger "update_docker_compose" "docker-compose installed successfully!"
                    whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "docker-compose installed successfully!" 8 78
                else
                    logger "update_docker_compose" "ERROR: Issue running newly installed docker-compose :-("
                    NEWT_COLORS='root=,red' \
                    whiptail \
                        --title "Error" \
                        --msgbox "Issue running newly installed docker-compose :-(" 8 78
                    exit_failure
                fi
            else
                logger "update_docker_compose" "ERROR: Problem chmodding docker-compose container wrapper script :-("
                NEWT_COLORS='root=,red' \
                    whiptail \
                        --title "Error" \
                        --msgbox "Problem chmodding docker-compose container wrapper script :-(" 8 78
                exit_failure
            fi
        else
            logger "update_docker_compose" "ERROR: Problem downloading docker-compose container wrapper script :-("
            NEWT_COLORS='root=,red' \
                whiptail \
                    --title "Error" \
                    --msgbox "Problem downloading docker-compose container wrapper script :-(" 8 78
            exit_failure
        fi
    fi
}

function install_docker_compose() {

    # Install current version of docker-compose as a container
    logger "install_docker_compose" "Installing docker-compose..."
    logger "install_docker_compose" "Attempting download of latest docker-compose container wrapper script"
    whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "Attempting installation of docker-compose container wrapper..." 8 78

    # TODO - Change to official installer once it supports multi-arch
    # see: https://github.com/docker/compose/issues/6831
    #URL_DOCKER_COMPOSE_INSTALLER="https://github.com/docker/compose/releases/download/$docker_compose_version_latest/run.sh"
    URL_DOCKER_COMPOSE_INSTALLER="https://raw.githubusercontent.com/linuxserver/docker-docker-compose/master/run.sh"

    if curl -L --fail "$URL_DOCKER_COMPOSE_INSTALLER" -o /usr/local/bin/docker-compose >> "$LOGFILE" 2>&1; then
        logger "install_docker_compose" "Download of latest docker-compose container wrapper script was OK"

        # Make executable
        logger "install_docker_compose" "Attempting 'chmod a+x /usr/local/bin/docker-compose'..."
        if chmod -v a+x /usr/local/bin/docker-compose >> "$LOGFILE" 2>&1; then
            logger "install_docker_compose" "'chmod a+x /usr/local/bin/docker-compose' was successful"

            # Make sure we can now run docker-compose and it is the latest version
            if docker-compose version >> "$LOGFILE" 2>&1; then
                logger "install_docker_compose" "docker-compose installed successfully!"
                whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "docker-compose installed successfully!" 8 78
            else
                logger "install_docker_compose" "ERROR: Issue running newly installed docker-compose :-("
                NEWT_COLORS='root=,red' \
                    whiptail \
                        --title "Error" \
                        --msgbox "Issue running newly installed docker-compose :-(" 8 78
                exit_failure
            fi
        else
            logger "install_docker_compose" "ERROR: Problem chmodding docker-compose container wrapper script :-("
            NEWT_COLORS='root=,red' \
                whiptail \
                    --title "Error" \
                    --msgbox "Problem chmodding docker-compose container wrapper script :-(" 8 78
            exit_failure
        fi
    else
        logger "install_docker_compose" "ERROR: Problem downloading docker-compose container wrapper script :-("
        NEWT_COLORS='root=,red' \
            whiptail \
                --title "Error" \
                --msgbox "Problem downloading docker-compose container wrapper script :-(" 8 78
        exit_failure
    fi
}

function input_timezone() {
    # Get timezone from user
    # -----------------

    source "$TMPFILE_NEWPREFS"

    # Prepare the default
    if [[ -e "/etc/timezone" ]]; then
        default="$(cat /etc/timezone)"
    else
        default="UTC"
    fi

    # Prepare the dialog
    msg="Please enter your feeder's timezone."
    title="Feeder Timezone"

    # User entry loop
    valid_input=0
    while [[ "$valid_input" -ne 1 ]]; do

        # Show dialog
        if FEEDER_TZ=$(whiptail \
            --clear \
            --backtitle "$WHIPTAIL_BACKTITLE" \
            --inputbox "$msg" \
            --title "$title" \
            9 78 \
            "$default" \
            3>&1 1>&2 2>&3); then
            :
        
        # If user presses cancel...
        else
            exit_user_cancelled
        fi

        # Ensure timezone entered is valid
        if [[ -n "$FEEDER_TZ" ]]; then
            if [[ -e "/usr/share/zoneinfo/$FEEDER_TZ" ]]; then
                valid_input=1    
            fi
        fi

        # If user input isn't valid, then let user know
        if [[ "$valid_input" -eq 0 ]]; then
            whiptail \
                --clear \
                --backtitle "$WHIPTAIL_BACKTITLE" \
                --msgbox "Please enter a valid timezone!" \
                --title "Invalid Timezone!" \
                8 40
        fi
    done

    # Set timezone
    logger "input_timezone" "Setting FEEDER_TZ=$FEEDER_TZ"
    set_env_file_entry FEEDER_TZ "$FEEDER_TZ"
}

function input_lat_long() {
    # Get lat/long input from user
    # -----------------

    source "$TMPFILE_NEWPREFS"

    # Prepare the dialog
    msg="Please enter your feeder's latitude (up to 5 decimal places)."
    title="Feeder Position"
    default="$FEEDER_LAT"

    valid_input=0
    while [[ "$valid_input" -ne 1 ]]; do

        # Show dialog
        if FEEDER_LAT=$(whiptail \
            --clear \
            --backtitle "$WHIPTAIL_BACKTITLE" \
            --inputbox "$msg" \
            --title "$title" \
            9 78 \
            "$default" \
            3>&1 1>&2 2>&3); then
            :
        
        # If user presses cancel...
        else
            exit_user_cancelled
        fi

        # Check to make sure latitude is valid
        if echo "$FEEDER_LAT" | grep -P "$REGEX_PATTERN_VALID_LAT_LONG" > /dev/null 2>&1; then
            valid_input=1
        fi

        # If user input isn't valid, then let user know
        if [[ "$valid_input" -eq 0 ]]; then
            whiptail \
                --clear \
                --backtitle "$WHIPTAIL_BACKTITLE" \
                --msgbox "Please enter a valid latitude!" \
                --title "Invalid Latitude!" \
                8 40
        fi
    done

    # Prepare the dialog
    msg="Please enter your feeder's longitude (up to 5 decimal places)."
    title="Feeder Position"
    default="$FEEDER_LONG"

    valid_input=0
    while [[ "$valid_input" -ne 1 ]]; do

        # Show dialog
        if FEEDER_LONG=$(whiptail \
            --clear \
            --backtitle "$WHIPTAIL_BACKTITLE" \
            --inputbox "$msg" \
            --title "$title" \
            9 78 \
            "$default" \
            3>&1 1>&2 2>&3); then
            :
        
        # If user presses cancel...
        else
            exit_user_cancelled
        fi

        # Check to make sure latitude is valid
        if echo "$FEEDER_LONG" | grep -P "$REGEX_PATTERN_VALID_LAT_LONG" > /dev/null 2>&1; then
            valid_input=1
        fi

        # If user input isn't valid, then let user know
        if [[ "$valid_input" -eq 0 ]]; then
            whiptail \
                --clear \
                --backtitle "$WHIPTAIL_BACKTITLE" \
                --msgbox "Please enter a valid longitude!" \
                --title "Invalid Longitude!" \
                8 40
        fi
    done

    logger "input_lat_long" "Setting FEEDER_LAT=$FEEDER_LAT"
    logger "input_lat_long" "Setting FEEDER_LONG=$FEEDER_LONG"
    set_env_file_entry FEEDER_LAT "$FEEDER_LAT"
    set_env_file_entry FEEDER_LONG "$FEEDER_LONG"
}

function input_altitude() {
    # Get altitude input from user
    # -----------------

    source "$TMPFILE_NEWPREFS"

    # Prepare the dialog
    msg="Please enter your feeder's altitude, suffixed with either 'm' for metres or 'ft' for feet."
    title="Feeder Altitude"
    default="$FEEDER_ALT"

    valid_input=0
    while [[ "$valid_input" -ne 1 ]]; do
        
        # Show dialog
        if FEEDER_ALT=$(whiptail \
            --clear \
            --backtitle "$WHIPTAIL_BACKTITLE" \
            --inputbox "$msg" \
            --title "$title" \
            9 78 \
            "$default" \
            3>&1 1>&2 2>&3); then
            :
        
        # If user presses cancel...
        else
            exit_user_cancelled
        fi

        # if answer was given in m...
        if echo "$FEEDER_ALT" | grep -P "$REGEX_PATTERN_VALID_ALT_M" > /dev/null 2>&1; then
            valid_input=1
            # convert m to ft
            bc_expression="scale=3; ${FEEDER_ALT%m} * 3.28084"
            FEEDER_ALT_M="${FEEDER_ALT%m}"
            FEEDER_ALT_FT="$(echo "$bc_expression" | docker exec -i "$CONTAINER_ID_TEMPORARY" bc -l)"

        # if answer was given in ft...
        elif echo "$FEEDER_ALT" | grep -P "$REGEX_PATTERN_VALID_ALT_FT" > /dev/null 2>&1; then
            # convert ft to m
            valid_input=1
            bc_expression="scale=3; ${FEEDER_ALT%ft} * 0.3048"
            FEEDER_ALT_M="$(echo "$bc_expression" | docker exec -i "$CONTAINER_ID_TEMPORARY" bc -l)"
            FEEDER_ALT_FT="${FEEDER_ALT%ft}"

        # if wrong answer was given...
        else
            # If user input isn't valid, then let user know
            whiptail \
                --clear \
                --backtitle "$WHIPTAIL_BACKTITLE" \
                --msgbox "Please enter a valid altitude!" \
                --title "Invalid Altitude!" \
                8 40
        fi
    done

    logger "input_altitude" "Setting FEEDER_ALT_M=$FEEDER_ALT_M"
    logger "input_altitude" "Setting FEEDER_ALT_FT=$FEEDER_ALT_FT"
    logger "input_altitude" "Setting FEEDER_ALT=$FEEDER_ALT"
    set_env_file_entry FEEDER_ALT_M "$FEEDER_ALT_M"
    set_env_file_entry FEEDER_ALT_FT "$FEEDER_ALT_FT"
    set_env_file_entry FEEDER_ALT "$FEEDER_ALT"

}

function input_adsbx_details() {
    # Get adsbx input from user
    # -----------------

    source "$TMPFILE_NEWPREFS"

    all_settings_valid=0
    while [[ "$all_settings_valid" -ne 1 ]]; do

        # Prepare the dialog
        msg="Please enter your ADSB Exchange UUID. If you don't have one, leave this field blank and a new UUID will be generated."
        title="ADSB Exchange"
        default="$ADSBX_UUID"

        valid_input=0
        while [[ "$valid_input" -ne 1 ]]; do

            # Show dialog
            if ADSBX_UUID=$(whiptail \
                --clear \
                --backtitle "$WHIPTAIL_BACKTITLE" \
                --inputbox "$msg" \
                --title "$title" \
                9 78 \
                "$default" \
                3>&1 1>&2 2>&3); then
                :
            
            # If user presses cancel...
            else
                exit_user_cancelled
            fi

            # If no input, generate a new UUID
            if [[ -z "$ADSBX_UUID" ]]; then
                logger "input_adsbx_details" "Generating new ADSB Exchange UUID..."
                whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "Generating new ADSB Exchange UUID..." 8 78
                if ADSBX_UUID=$(docker run --rm -it --entrypoint uuidgen mikenye/adsbexchange -t 2>/dev/null); then
                    logger "input_adsbx_details" "New ADSB Exchange UUID generated OK: $ADSBX_UUID"
                    echo ""
                    valid_input=1
                    whiptail \
                        --clear \
                        --backtitle "$WHIPTAIL_BACKTITLE" \
                        --msgbox "New ADSB Exchange UUID generated OK: $ADSBX_UUID" \
                        --title "New ADSB Exchange UUID" \
                        8 40
                else
                    logger "input_adsbx_details" "ERROR: Problem generating new ADSB Exchange UUID :-("
                    NEWT_COLORS='root=,red' \
                        whiptail \
                            --title "Error" \
                            --msgbox "Problem generating new ADSB Exchange UUID :-(" 8 78
                    exit_failure
                fi
            else
                valid_input=1
            fi

            # If user input isn't valid, then let user know
            if [[ "$valid_input" -eq 0 ]]; then
                whiptail \
                    --clear \
                    --backtitle "$WHIPTAIL_BACKTITLE" \
                    --msgbox "Please enter a valid UUID!" \
                    --title "Invalid UUID!" \
                    8 40
            fi

        done

        # Prepare the dialog
        msg="Please enter a unique name for the ADSB Exchange feeder."
        title="ADSB Exchange"
        default="$ADSBX_SITENAME"

        valid_input=0
        while [[ "$valid_input" -ne 1 ]]; do

            # Show dialog
            if ADSBX_SITENAME=$(whiptail \
                --clear \
                --backtitle "$WHIPTAIL_BACKTITLE" \
                --inputbox "$msg" \
                --title "$title" \
                9 78 \
                "$default" \
                3>&1 1>&2 2>&3); then
                :
            
            # If user presses cancel...
            else
                exit_user_cancelled
            fi

            # Check for valid input
            if [[ -n "$ADSBX_SITENAME" ]]; then
                NOSPACENAME="$(echo -n -e "${ADSBX_SITENAME}" | tr -c '[a-zA-Z0-9]_\- ' '_')"
                if echo "$NOSPACENAME" | grep -P "$REGEX_PATTERN_VALID_ADSBX_SITENAME" > /dev/null 2>&1; then
                # if sitename already contains _XX, then we don't need to add another random number...
                    ADSBX_SITENAME="$NOSPACENAME"
                else
                    ADSBX_SITENAME="${NOSPACENAME}_$((RANDOM % 90 + 10))"
                fi
                logger "input_adsbx_details" "Your ADSB Exchange site name will be set to: $ADSBX_SITENAME" "$LIGHTBLUE"
                valid_input=1
            fi

            # If user input isn't valid, then let user know
            if [[ "$valid_input" -eq 0 ]]; then
                whiptail \
                    --clear \
                    --backtitle "$WHIPTAIL_BACKTITLE" \
                    --msgbox "Please enter a valid site name!" \
                    --title "Invalid site name!" \
                    8 40
            fi
        done

        msg="Please confirm your ADSB Exchange settings:\n\n"
        msg+=" - ADSB_UUID=$ADSBX_UUID\n"
        msg+=" - ADSBX_SITENAME=$ADSBX_SITENAME\n"
        if whiptail \
                --clear \
                --backtitle "$WHIPTAIL_BACKTITLE" \
                --title "Confirm ADSB Exchange Settings" \
                --yes-button "Accept Settings" \
                --no-button "Change Settings" \
                --yesno "$msg" \
                10 78; then
            all_settings_valid=1
        fi

    done

    logger "input_adsbx_details" "Setting ADSBX_UUID=$ADSBX_UUID"
    logger "input_adsbx_details" "Setting ADSBX_SITENAME=$ADSBX_SITENAME"
    set_env_file_entry ADSBX_UUID "$ADSBX_UUID"
    set_env_file_entry ADSBX_SITENAME "$ADSBX_SITENAME"

}

function input_fr24_details() {
    # Get fr24 input from user
    # -----------------

    source "$TMPFILE_NEWPREFS"

    all_settings_valid=0
    while [[ "$all_settings_valid" -ne 1 ]]; do

        # Prepare the dialog
        msg="Please enter your Flightradar24 key. If you don't have one, leave the field blank and you will be taken through the sign-up process."
        title="Flightradar24"
        default="$FR24_KEY"
        
        valid_input=0
        while [[ "$valid_input" -ne 1 ]]; do
            
            # Show dialog
            if FR24_KEY=$(whiptail \
                --clear \
                --backtitle "$WHIPTAIL_BACKTITLE" \
                --inputbox "$msg" \
                --title "$title" \
                9 78 \
                "$default" \
                3>&1 1>&2 2>&3); then
                :
            
            # If user presses cancel...
            else
                exit_user_cancelled
            fi

            # need to run sign up process
            if [[ -z "$FR24_KEY" ]]; then
                
                # get email
                valid_email=0
                while [[ "$valid_email" -ne 1 ]]; do
                    # Show dialog
                    if FR24_EMAIL=$(whiptail \
                        --clear \
                        --backtitle "$WHIPTAIL_BACKTITLE" \
                        --inputbox "Please enter a valid email address for your Flightradar24 feeder." \
                        --title "$title" \
                        9 78 \
                        "$default" \
                        3>&1 1>&2 2>&3); then
                        :
                    
                    # If user presses cancel...
                    else
                        exit_user_cancelled
                    fi

                    if echo "$FR24_EMAIL" | grep -P "$REGEX_PATTERN_VALID_EMAIL_ADDRESS" > /dev/null 2>&1; then
                        valid_email=1
                    else
                        whiptail \
                            --clear \
                            --backtitle "$WHIPTAIL_BACKTITLE" \
                            --msgbox "Please enter a valid email address!" \
                            --title "Invalid email addreess!" \
                            8 40
                    fi

                done
                
                # run through sign-up process
                # pull & start container
                logger "input_fr24_details" "Running flightradar24 sign-up process (takes up to 2 mins)..."
                whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "Running flightradar24 sign-up process (takes up to 2 mins)..." 8 78

                if docker pull mikenye/fr24feed >> "$LOGFILE" 2>&1; then
                    :
                else
                    NEWT_COLORS='root=,red' \
                        whiptail \
                            --title "Error" \
                            --msgbox "Failed to pull (download) mikenye/fr24feed :-(" 8 78
                    exit_failure
                fi

                CONTAINER_ID_FR24=$(docker run -d --rm -it --entrypoint fr24feed mikenye/fr24feed --signup)
                # write out expect script to attach to container and issue commands
                write_fr24_expectscript "$CONTAINER_ID_FR24"
                # run expect script & interpret output
                logger "input_fr24_details" "Running expect script..."
                if expect "$TMPFILE_FR24SIGNUP_EXPECT" >> "$TMPFILE_FR24SIGNUP_LOG" 2>&1; then
                    logger "input_fr24_details" "Expect script finished OK"
                else
                    logger "input_fr24_details" "ERROR: Problem running flightradar24 sign-up process :-("
                    NEWT_COLORS='root=,red' \
                        whiptail \
                            --title "Error" \
                            --msgbox "Problem running flightradar24 sign-up process :-(" 8 78
                    docker logs "$CONTAINER_ID_FR24" >> "$LOGFILE"
                    docker kill "$CONTAINER_ID_FR24" > /dev/null 2>&1 || true
                    exit_failure
                fi

                docker logs "$CONTAINER_ID_FR24" > "$TMPFILE_FR24SIGNUP_LOG"
                docker kill "$CONTAINER_ID_FR24" > /dev/null 2>&1 || true
                
                # try to get sharing key
                if grep -P "$REGEX_PATTERN_FR24_SHARING_KEY" "$TMPFILE_FR24SIGNUP_LOG" >> "$LOGFILE" 2>&1; then
                    FR24_EMAIL=$(grep -P "$REGEX_PATTERN_FR24_SHARING_KEY" "$TMPFILE_FR24SIGNUP_LOG" | \
                    sed -r "s/$REGEX_PATTERN_FR24_SHARING_KEY/\1/")
                    logger "input_fr24_details" "Your new flightradar24 sharing key is: $FR24_EMAIL"
                    valid_input=1
                else
                    logger "input_fr24_details" "ERROR: Could not find flightradar24 sharing key :-("
                    NEWT_COLORS='root=,red' \
                        whiptail \
                            --title "Error" \
                            --msgbox "Could not find flightradar24 sharing key :-(" 8 78
                    cat "$TMPFILE_FR24SIGNUP_LOG" >> "$LOGFILE"
                    valid_input=0
                    exit_failure
                fi

                # try to get radar ID
                if grep -P "$REGEX_PATTERN_FR24_RADAR_ID" "$TMPFILE_FR24SIGNUP_LOG" >> "$LOGFILE" 2>&1; then
                    FR24_RADAR_ID=$(grep -P "$REGEX_PATTERN_FR24_RADAR_ID" "$TMPFILE_FR24SIGNUP_LOG" | \
                    sed -r "s/$REGEX_PATTERN_FR24_RADAR_ID/\1/")
                    logger "input_fr24_details" "Your new flightradar24 radar ID is: $FR24_RADAR_ID"
                    valid_input=1
                else
                    logger "input_fr24_details" "ERROR: Could not find flightradar24 radar ID :-("
                    NEWT_COLORS='root=,red' \
                        whiptail \
                            --title "Error" \
                            --msgbox "Could not find flightradar24 radar ID :-(" 8 78
                    cat "$TMPFILE_FR24SIGNUP_LOG" >> "$LOGFILE"
                    valid_input=0
                    exit_failure
                fi

                msg="New Flightradar24 feeder details:\n"
                msg+=" - FR24_KEY=$FR24_KEY\n"
                msg+=" - FR24_RADAR_ID=$FR24_RADAR_ID"
                whiptail \
                    --clear \
                    --backtitle "$WHIPTAIL_BACKTITLE" \
                    --title "New Flightradar24 feeder details" \
                    --msgbox "$msg" \
                    8 40

            else
                valid_input=1
            fi
        done

        msg="Please confirm your Flightradar24 settings:\n\n"
        msg+=" - FR24_KEY=$FR24_KEY\n"
        if whiptail \
                --clear \
                --backtitle "$WHIPTAIL_BACKTITLE" \
                --title "Confirm Flightradar24 Settings" \
                --yes-button "Accept Settings" \
                --no-button "Change Settings" \
                --yesno "$msg" \
                10 78; then
            all_settings_valid=1
        fi
    done

    logger "input_fr24_details" "Setting FR24_KEY=$FR24_KEY"
    logger "input_fr24_details" "FR24_RADAR_ID=$FR24_RADAR_ID"
    logger "input_fr24_details" "FR24_EMAIL=$FR24_EMAIL"
    set_env_file_entry FR24_KEY "$FR24_KEY"
}

function input_piaware_details() {
    # Get piaware input from user
    # -----------------

    source "$TMPFILE_NEWPREFS"

    all_settings_valid=0
    while [[ "$all_settings_valid" -ne 1 ]]; do

        # Prepare the dialog
        msg="Please enter your FlightAware (piaware) feeder ID. If you don't have one, leave the field blank and a new one will be generated."
        title="FlightAware (piaware)"
        default="$PIAWARE_FEEDER_ID"
        
        valid_input=0
        while [[ "$valid_input" -ne 1 ]]; do
            
            # Show dialog
            if PIAWARE_FEEDER_ID=$(whiptail \
                --clear \
                --backtitle "$WHIPTAIL_BACKTITLE" \
                --inputbox "$msg" \
                --title "$title" \
                9 78 \
                "$default" \
                3>&1 1>&2 2>&3); then
                :
            
            # If user presses cancel...
            else
                exit_user_cancelled
            fi

            # need to generate a new feeder id
            if [[ -z "$PIAWARE_FEEDER_ID" ]]; then
                
                # run through sign-up process
                logger "input_piaware_details" "Running piaware feeder-id generation process (takes approx. 30 seconds)..."
                whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "Running piaware feeder-id generation process (takes approx. 30 seconds)..." 8 78

                if docker pull mikenye/piaware >> "$LOGFILE" 2>&1; then
                    :
                else
                    NEWT_COLORS='root=,red' \
                        whiptail \
                            --title "Error" \
                            --msgbox "Failed to pull (download) mikenye/piaware :-(" 8 78
                    exit_failure
                fi

                source "$TMPFILE_NEWPREFS"
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
                if expect "$TMPFILE_PIAWARESIGNUP_EXPECT" >> "$LOGFILE" 2>&1; then
                    logger "input_piaware_details" "Expect script finished OK"
                    valid_input=1
                else
                    logger "input_piaware_details" "ERROR: Problem running piaware feeder-id generation process :-("
                    NEWT_COLORS='root=,red' \
                        whiptail \
                            --title "Error" \
                            --msgbox "Problem running piaware feeder-id generation process :-(" 8 78
                    docker logs "$CONTAINER_ID_PIAWARE" >> "$LOGFILE"
                    valid_input=0
                    docker kill "$CONTAINER_ID_PIAWARE" > /dev/null 2>&1 || true
                    exit_failure
                fi

                docker logs "$CONTAINER_ID_PIAWARE" > "$TMPFILE_PIAWARESIGNUP_LOG"
                docker kill "$CONTAINER_ID_PIAWARE" > /dev/null 2>&1 || true
                
                # try to retrieve the feeder ID from the container log
                if grep -oP "$REGEX_PATTERN_PIAWARE_FEEDER_ID" "$TMPFILE_PIAWARESIGNUP_LOG" > /dev/null 2>&1; then
                    PIAWARE_FEEDER_ID=$(grep -oP "$REGEX_PATTERN_PIAWARE_FEEDER_ID" "$TMPFILE_PIAWARESIGNUP_LOG")
                    logger "input_piaware_details" "Your new piaware feeder-id is: $PIAWARE_FEEDER_ID"
                    valid_input=1
                else
                    logger "input_piaware_details" "ERROR: Could not find piaware feeder-id :-("
                    NEWT_COLORS='root=,red' \
                        whiptail \
                            --title "Error" \
                            --msgbox "Could not find piaware feeder-id :-(" 8 78
                    cat "$TMPFILE_PIAWARESIGNUP_LOG" >> "$LOGFILE"
                    exit_failure
                fi

                msg="New FlightAware (piaware) feeder details:\n"
                msg+=" - PIAWARE_FEEDER_ID=$PIAWARE_FEEDER_ID\n"
                whiptail \
                    --clear \
                    --backtitle "$WHIPTAIL_BACKTITLE" \
                    --title "New FlightAware Feeder Details" \
                    --msgbox "$msg" \
                    8 70

            else
                valid_input=1
            fi
        done

        msg="Please confirm your FlightAware (piaware) settings:\n\n"
        msg+=" - PIAWARE_FEEDER_ID=$PIAWARE_FEEDER_ID\n"
        if whiptail \
                --clear \
                --backtitle "$WHIPTAIL_BACKTITLE" \
                --title "Confirm FlightAware (piaware) Settings" \
                --yes-button "Accept Settings" \
                --no-button "Change Settings" \
                --yesno "$msg" \
                10 78; then
            all_settings_valid=1
        fi
    done

    logger "input_piaware_details" "Setting PIAWARE_FEEDER_ID=$PIAWARE_FEEDER_ID"
    set_env_file_entry PIAWARE_FEEDER_ID "$PIAWARE_FEEDER_ID"
}

function input_planefinder_details() {
    # Get piaware input from user
    # -----------------

    source "$TMPFILE_NEWPREFS"

    all_settings_valid=0
    while [[ "$all_settings_valid" -ne 1 ]]; do

        # Prepare the dialog
        msg="Please enter your Planefinder share code. If you don't have one, leave the field blank and a new one will be generated."
        title="Planefinder"
        default="$PLANEFINDER_SHARECODE"
        
        valid_input=0
        while [[ "$valid_input" -ne 1 ]]; do
            
            # Show dialog
            if PLANEFINDER_SHARECODE=$(whiptail \
                --clear \
                --backtitle "$WHIPTAIL_BACKTITLE" \
                --inputbox "$msg" \
                --title "$title" \
                9 78 \
                "$default" \
                3>&1 1>&2 2>&3); then
                :
            
            # If user presses cancel...
            else
                exit_user_cancelled
            fi

            # need to generate a new feeder id
            if [[ -z "$PLANEFINDER_SHARECODE" ]]; then

                # get email
                valid_email=0
                while [[ "$valid_email" -ne 1 ]]; do
                    # Show dialog
                    if PLANEFINDER_EMAIL=$(whiptail \
                        --clear \
                        --backtitle "$WHIPTAIL_BACKTITLE" \
                        --inputbox "Please enter a valid email address for your Planefinder feeder." \
                        --title "$title" \
                        9 78 \
                        "$default" \
                        3>&1 1>&2 2>&3); then
                        :
                    
                    # If user presses cancel...
                    else
                        exit_user_cancelled
                    fi

                    if echo "$PLANEFINDER_EMAIL" | grep -P "$REGEX_PATTERN_VALID_EMAIL_ADDRESS" > /dev/null 2>&1; then
                        valid_email=1
                    else
                        whiptail \
                            --clear \
                            --backtitle "$WHIPTAIL_BACKTITLE" \
                            --msgbox "Please enter a valid email address!" \
                            --title "Invalid email addreess!" \
                            8 40
                    fi
                done
                
                # run through sign-up process
                logger "input_planefinder_details" "Running Planefinder share code generation process (takes a few seconds)..."
                whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "Running Planefinder share code generation process (takes a few seconds)..." 8 78

                # prepare form data
                planefinder_registration_data="email=$(echo -n "$PLANEFINDER_EMAIL" | docker exec -i "$CONTAINER_ID_TEMPORARY" jq -sRr @uri)"
                planefinder_registration_data+="&lat=$FEEDER_LAT"
                planefinder_registration_data+="&lon=$FEEDER_LONG"
                planefinder_registration_data+="&r=register"
                logger "input_planefinder_details" "$planefinder_registration_data"

                # submit the form and capture the results
                planefinder_registration_json=$(curl "$URL_PLANEFINDER_REGISTRATION" \
                    --silent \
                    -XPOST \
                    -H 'Accept: application/json, text/javascript, */*; q=0.01' \
                    -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
                    -H "Content-Length: ${#planefinder_registration_data}" \
                    -H 'Host: dataupload.planefinder.net' \
                    -H 'Accept-Encoding: gzip, deflate' \
                    -H 'Connection: keep-alive' \
                    --data "$planefinder_registration_data" \
                    --output - | gunzip)

                # make sure the returned JSON is valid
                if echo "$planefinder_registration_json" | docker exec -i "$CONTAINER_ID_TEMPORARY" jq . >> "$LOGFILE" 2>&1; then
                    logger "input_planefinder_details" "JSON validated OK"
                else
                    logger "input_planefinder_details" "ERROR: Could not interpret response from planefinder :-("
                    logger "input_planefinder_details" "$planefinder_registration_json"
                    NEWT_COLORS='root=,red' \
                        whiptail \
                            --title "Error" \
                            --msgbox "Could not interpret response from planefinder :-(" 8 78
                    exit_failure
                fi

                # make sure the returned JSON contains "success=true"
                if [[ "$(echo "$planefinder_registration_json" | docker exec -i "$CONTAINER_ID_TEMPORARY" jq .success)" == "true" ]]; then
                    logger "input_planefinder_details" "returned JSON contains 'success=true'"
                else
                    logger "input_planefinder_details" "ERROR: Response from planefinder was not successful :-("
                    logger "input_planefinder_details" "$planefinder_registration_json"
                    NEWT_COLORS='root=,red' \
                        whiptail \
                            --title "Error" \
                            --msgbox "Response from planefinder was not successful :-(" 8 78
                    exit_failure
                fi

                # make sure we can get the share code
                if PLANEFINDER_SHARECODE=$(echo "$planefinder_registration_json" | docker exec -i "$CONTAINER_ID_TEMPORARY" jq .payload.sharecode | tr -d '"'); then
                    logger "input_planefinder_details" "Your new planefinder sharecode is: $PLANEFINDER_SHARECODE"
                    valid_input=1
                else
                    logger "input_planefinder_details" "ERROR: Could not determine planefinder sharecode from response :-("
                    logger "input_planefinder_details" "$planefinder_registration_json"
                    NEWT_COLORS='root=,red' \
                        whiptail \
                            --title "Error" \
                            --msgbox "Could not determine planefinder sharecode from response :-(" 8 78
                    exit_failure
                fi
            else
                valid_input=1
            fi
        done

        msg="Please confirm your Planefinder settings:\n\n"
        msg+=" - PLANEFINDER_SHARECODE=$PLANEFINDER_SHARECODE\n"
        if whiptail \
                --clear \
                --backtitle "$WHIPTAIL_BACKTITLE" \
                --title "Confirm Planefinder Settings" \
                --yes-button "Accept Settings" \
                --no-button "Change Settings" \
                --yesno "$msg" \
                10 78; then
            all_settings_valid=1
        fi

    done

    logger "input_planefinder_details" "Setting PLANEFINDER_SHARECODE=$PLANEFINDER_SHARECODE"
    logger "input_planefinder_details" "PLANEFINDER_EMAIL=$PLANEFINDER_EMAIL"
    set_env_file_entry PLANEFINDER_SHARECODE "$PLANEFINDER_SHARECODE"
}

function input_opensky_details() {
    # Get opensky input from user
    # -----------------

    # Let the user know that they should go and register for an account at OpenSky
    title="OpenSky Network"
    msg="Please ensure you have registered for an account on the OpenSky Network website, "
    msg+="(https://opensky-network.org/). You will need your OpenSky Network username in the next step."
    whiptail \
        --clear \
        --backtitle "$WHIPTAIL_BACKTITLE" \
        --title "$title" \
        --msgbox "$msg" \
        9 78

    source "$TMPFILE_NEWPREFS"

    all_settings_valid=0
    while [[ "$all_settings_valid" -ne 1 ]]; do

        # Prepare the dialog
        msg="Please enter your OpenSky Network username"
        default="$OPENSKY_USERNAME"

        # Opensky username
        valid_input=0
        while [[ "$valid_input" -ne 1 ]]; do

            # Show dialog
            if OPENSKY_USERNAME=$(whiptail \
                --clear \
                --backtitle "$WHIPTAIL_BACKTITLE" \
                --inputbox "$msg" \
                --title "$title" \
                9 78 \
                "$default" \
                3>&1 1>&2 2>&3); then
                :
            
            # If user presses cancel...
            else
                exit_user_cancelled
            fi

            if echo "$OPENSKY_USERNAME" | grep -P "$REGEX_PATTERN_NOT_EMPTY" > /dev/null 2>&1; then
                valid_input=1
            else
                whiptail \
                    --clear \
                    --backtitle "$WHIPTAIL_BACKTITLE" \
                    --msgbox "Please enter a valid username!" \
                    --title "Invalid username!" \
                    8 40
            fi
        done

        # Opensky serial
        # Prepare the dialog
        msg="Please enter this feeder's OpenSky serial. If you don't have one, leave the field blank and a new one will be generated."
        default="$OPENSKY_SERIAL"

        # Opensky serial
        valid_input=0
        while [[ "$valid_input" -ne 1 ]]; do

            # Show dialog
            if OPENSKY_SERIAL=$(whiptail \
                --clear \
                --backtitle "$WHIPTAIL_BACKTITLE" \
                --inputbox "$msg" \
                --title "$title" \
                9 78 \
                -- "$default" \
                3>&1 1>&2 2>&3); then
                :
            
            # If user presses cancel...
            else
                exit_user_cancelled
            fi

            # need to generate a new feeder id
            if [[ -z "$OPENSKY_SERIAL" ]]; then

                # run through sign-up process
                logger "input_opensky_details" "Running OpenSky Network serial generation process (takes a few seconds)..."
                whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "Running OpenSky Network serial generation process (takes a few seconds)..." 8 78

                if docker pull mikenye/opensky-network >> "$LOGFILE" 2>&1; then
                    :
                else
                    NEWT_COLORS='root=,red' \
                        whiptail \
                            --title "Error" \
                            --msgbox "Failed to pull (download) mikenye/opensky-network :-(" 8 78
                    exit_failure
                fi

                CONTAINER_ID_OPENSKY=$(docker run \
                    -d \
                    --rm \
                    -it \
                    -e BEASTHOST=127.0.0.99 \
                    -e LAT="$FEEDER_LAT" \
                    -e LONG="$FEEDER_LONG" \
                    -e ALT="$FEEDER_ALT_M" \
                    -e OPENSKY_USERNAME="$OPENSKY_USERNAME" \
                    mikenye/opensky-network)
                
                # run expect script (to wait until logged in and a feeder ID is generated)
                write_opensky_expectscript "$CONTAINER_ID_OPENSKY"

                if expect "$TMPFILE_OPENSKYSIGNUP_EXPECT" >> "$LOGFILE" 2>&1; then
                    logger "input_opensky_details" "Expect script finished OK"
                else
                    logger "input_opensky_details" "ERROR: Problem running opensky serial generation process :-("
                    NEWT_COLORS='root=,red' \
                        whiptail \
                            --title "Error" \
                            --msgbox "Problem running opensky serial generation process :-(" 8 78
                    docker logs "$CONTAINER_ID_OPENSKY" >> "$LOGFILE"
                    docker kill "$CONTAINER_ID_OPENSKY" > /dev/null 2>&1 || true
                    exit_failure
                fi

                docker logs "$CONTAINER_ID_OPENSKY" > "$TMPFILE_OPENSKYSIGNUP_LOG"
                docker kill "$CONTAINER_ID_OPENSKY" > /dev/null 2>&1 || true
                
                # try to retrieve the feeder ID from the container log
                if grep -oP "$REGEX_PATTERN_OPENSKY_SERIAL" "$TMPFILE_OPENSKYSIGNUP_LOG" > /dev/null 2>&1; then
                    OPENSKY_SERIAL=$(grep -oP "$REGEX_PATTERN_OPENSKY_SERIAL" "$TMPFILE_OPENSKYSIGNUP_LOG")
                    logger "input_opensky_details" "Your new opensky serial is: $OPENSKY_SERIAL"
                    valid_input=1
                else
                    logger "input_opensky_details" "ERROR: Could not find opensky serial :-("
                    NEWT_COLORS='root=,red' \
                        whiptail \
                            --title "Error" \
                            --msgbox "Could not find opensky serial :-(" 8 78
                    cat "$TMPFILE_OPENSKYSIGNUP_LOG" >> "$LOGFILE"
                    exit_failure
                fi

            else
                valid_input=1
            fi
        done

        msg="Please confirm your OpenSky Network settings:\n\n"
        msg+=" - OPENSKY_USERNAME=$OPENSKY_USERNAME\n"
        msg+=" - OPENSKY_SERIAL=$OPENSKY_SERIAL"
        if whiptail \
                --clear \
                --backtitle "$WHIPTAIL_BACKTITLE" \
                --title "Confirm OpenSky Network Settings" \
                --yes-button "Accept Settings" \
                --no-button "Change Settings" \
                --yesno "$msg" \
                10 78; then
            all_settings_valid=1
        fi
    done

    logger "input_opensky_details" "Setting OPENSKY_USERNAME=$OPENSKY_USERNAME"
    logger "input_opensky_details" "Setting OPENSKY_SERIAL=$OPENSKY_SERIAL"
    set_env_file_entry OPENSKY_USERNAME "$OPENSKY_USERNAME"
    set_env_file_entry OPENSKY_SERIAL "$OPENSKY_SERIAL"
}

function input_radarbox_details() {
    # Get piaware input from user
    # -----------------

    source "$TMPFILE_NEWPREFS"

    all_settings_valid=0
    while [[ "$all_settings_valid" -ne 1 ]]; do

        # Prepare the dialog
        title="Radarbox"
        msg="Please enter your Radarbox sharing key. If you don't have one, leave the field blank and a new one will be generated."
        default="$RADARBOX_SHARING_KEY"

        # Radarbox
        valid_input=0
        while [[ "$valid_input" -ne 1 ]]; do

            # Show dialog
            if RADARBOX_SHARING_KEY=$(whiptail \
                --clear \
                --backtitle "$WHIPTAIL_BACKTITLE" \
                --inputbox "$msg" \
                --title "$title" \
                9 78 \
                "$default" \
                3>&1 1>&2 2>&3); then
                :
            
            # If user presses cancel...
            else
                exit_user_cancelled
            fi

            # need to generate a new feeder id
            if [[ -z "$RADARBOX_SHARING_KEY" ]]; then
                
                # run through sign-up process
                logger "input_radarbox_details" "Running radarbox sharing key generation process (takes a few seconds)..."
                whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "Running radarbox sharing key generation process (takes a few seconds)..." 8 78

                if docker pull mikenye/radarbox >> "$LOGFILE" 2>&1; then
                    :
                else
                    NEWT_COLORS='root=,red' \
                        whiptail \
                            --title "Error" \
                            --msgbox "Failed to pull (download) mikenye/radarbox :-(" 8 78
                    exit_failure
                fi

                # prepare to run the container
                # set up fake thermal area (see: https://github.com/mikenye/docker-radarbox/issues/16)
                source "$TMPFILE_NEWPREFS"
                mkdir -p "$TMPDIR_RBFEEDER_FAKETHERMAL/thermal_zone0/"
                echo "24000" > "$TMPDIR_RBFEEDER_FAKETHERMAL/thermal_zone0/temp"
                CONTAINER_ID_RBFEEDER=$(docker run \
                    --rm \
                    -it \
                    -d \
                    -e BEASTHOST=127.0.0.99 \
                    -e LAT="$FEEDER_LAT" \
                    -e LONG="$FEEDER_LONG" \
                    -e ALT="$FEEDER_ALT_M" \
                    -v "$TMPDIR_RBFEEDER_FAKETHERMAL":/sys/class/thermal:ro \
                    mikenye/radarbox)
                
                # run expect script (to wait until logged in and a feeder ID is generated)
                write_rbfeeder_expectscript "$CONTAINER_ID_RBFEEDER"
                if expect "$TMPFILE_RBFEEDERSIGNUP_EXPECT" >> "$LOGFILE" 2>&1; then
                    logger "input_radarbox_details" "Expect script finished OK"
                    valid_input=1
                else
                    logger "input_radarbox_details" "ERROR: Problem running radarbox sharing key generation process :-("
                    NEWT_COLORS='root=,red' \
                        whiptail \
                            --title "Error" \
                            --msgbox "Problem running radarbox sharing key generation process :-(" 8 78
                    docker logs "$CONTAINER_ID_RBFEEDER" >> "$LOGFILE"
                    valid_input=0
                    docker kill "$CONTAINER_ID_RBFEEDER" > /dev/null 2>&1 || true
                    exit_failure
                fi

                docker logs "$CONTAINER_ID_RBFEEDER" > "$TMPFILE_RBFEEDERSIGNUP_LOG"
                docker kill "$CONTAINER_ID_RBFEEDER" > /dev/null 2>&1 || true
                
                # try to retrieve the feeder ID from the container log
                if grep -oP "$REGEX_PATTERN_RBFEEDER_KEY" "$TMPFILE_RBFEEDERSIGNUP_LOG" > /dev/null 2>&1; then
                    RADARBOX_SHARING_KEY=$(grep -oP "$REGEX_PATTERN_RBFEEDER_KEY" "$TMPFILE_RBFEEDERSIGNUP_LOG" | tr -d '.')
                    logger "input_radarbox_details" "Your new radarbox sharing key is: $RADARBOX_SHARING_KEY"
                    valid_input=1
                else
                    logger "input_radarbox_details" "ERROR: Could not find radarbox sharing key :-("
                    NEWT_COLORS='root=,red' \
                        whiptail \
                            --title "Error" \
                            --msgbox "Could not find radarbox sharing key :-(" 8 78
                    cat "$TMPFILE_RBFEEDERSIGNUP_LOG" >> "$LOGFILE"
                    exit_failure
                fi
            else
                valid_input=1
            fi
        done

        msg="Please confirm your Radarbox settings:\n\n"
        msg+=" - RADARBOX_SHARING_KEY=$RADARBOX_SHARING_KEY"
        if whiptail \
                --clear \
                --backtitle "$WHIPTAIL_BACKTITLE" \
                --title "Confirm Radarbox Settings" \
                --yes-button "Accept Settings" \
                --no-button "Change Settings" \
                --yesno "$msg" \
                10 78; then
            all_settings_valid=1
        fi
    done

    logger "input_radarbox_details" "Setting RADARBOX_SHARING_KEY=$OPENSKY_SERIAL"
    set_env_file_entry RADARBOX_SHARING_KEY "$RADARBOX_SHARING_KEY"

}

function find_rtlsdr_devices() {

    # clone rtl-sdr repo
    logger "find_rtlsdr_devices" "Attempting to clone RTL-SDR repo..."
    if git clone --depth 1 "$URL_REPO_RTLSDR" "$TMPDIR_REPO_RTLSDR" >> "$LOGFILE" 2>&1; then
        logger "find_rtlsdr_devices" "Clone of RTL-SDR repo OK"
    else
        logger "find_rtlsdr_devices" "ERROR: Problem cloneing RTL-SDR repo :-(" "$LIGHTRED"
        exit_failure
    fi

    # ensure the rtl-sdr.rules file exists
    if [[ -e "$TMPDIR_REPO_RTLSDR/rtl-sdr.rules" ]]; then

        # loop through each line of rtl-sdr.rules and look for radio
        while read -r line; do

            # only care about lines with radio info
            if echo "$line" | grep 'SUBSYSTEMS=="usb"' > /dev/null 2>&1; then

                # get idVendor & idProduct to look for
                idVendor=$(echo "$line" | grep -oP "$REGEX_PATTERN_RTLSDR_RULES_IDVENDOR")
                idProduct=$(echo "$line" | grep -oP "$REGEX_PATTERN_RTLSDR_RULES_IDPRODUCT")

                # look for the USB devices
                for lsusbline in $(lsusb -d "$idVendor:$idProduct"); do

                    # get bus & device number
                    usb_bus=$(echo "$lsusbline" | grep -oP "$REGEX_PATTERN_LSUSB_BUSNUMBER")
                    usb_device=$(echo "$lsusbline" | grep -oP "$REGEX_PATTERN_LSUSB_DEVICENUMBER")

                    # add to list of radios
                    if [[ -c "/dev/bus/usb/$usb_bus/$usb_device" ]]; then
                        echo " * Found RTL-SDR device at /dev/bus/usb/$usb_bus/$usb_device"
                        RTLSDR_DEVICES+=("/dev/bus/usb/$usb_bus/$usb_device")
                    fi

                done
            fi 

        done < "$TMPDIR_REPO_RTLSDR/rtl-sdr.rules"

    else
        logger "find_rtlsdr_devices" "ERROR: Could not find rtl-sdr.rules :-(" "$LIGHTRED"
        exit_failure
    fi

}

function show_preferences() {

    source "$TMPFILE_NEWPREFS"

    echo ""
    echo -e "${WHITE}===== Configured Preferences =====${NOCOLOR}"
    echo ""

    # Feeder position
    echo " * Feeder timezone is: $FEEDER_TZ"
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
    else
        echo " * No feeding to Flightradar24"
    fi

    # Opensky
    if [[ "$FEED_OPENSKY" == "y" ]]; then
        echo " * OpenSky Network docker container will be created and configured"
        echo "     - OpenSky Network Username: $OPENSKY_USERNAME"
        echo "     - OpenSky Serial Number: $OPENSKY_SERIAL"
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
        echo "     - PlaneFinder Sharecode: $PLANEFINDER_SHARECODE"
    else
        echo " * No feeding to PlaneFinder"
    fi

    # RADARBOX
    if [[ "$FEED_RADARBOX" == "y" ]]; then
        echo " * AirNav RadarBox docker container will be created and configured"
        echo "     - Radarbox Sharing Key: $RADARBOX_SHARING_KEY"
    else
        echo " * No feeding to AirNav RadarBox"
    fi
    echo ""
}

function get_rtlsdr_preferences() {

    source "$TMPFILE_NEWPREFS"

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

function set_env_file_entry() {
    # $1 = variable name
    # $2 = variable value
    #---------------------
    # delete the old line (if it exists)
    sed -i "/^$1=/d" "$TMPFILE_NEWPREFS"
    # write the new line
    echo "$1=$2" >> "$TMPFILE_NEWPREFS"
    # fix any non-unix line endings
    sed -i 's/\r//g' "$TMPFILE_NEWPREFS"
    # log stuff
    logger "set_env_file_entry" "Setting $1=$2 in $TMPFILE_NEWPREFS"
}

function del_env_file_entry() {
    # $1 = variable name
    #--------------------
    # delete the line containing the variable
    sed -i "/^$1=/d" file
}

function get_feeder_preferences() {

    # Present the user with a checklist of supported feeder services
    if feeder_prefs=$(whiptail --backtitle "$WHIPTAIL_BACKTITLE" \
        --title "Feeder Preferences" \
        --checklist "Choose services to feed:" 20 78 10 \
        "FEED_ADSBX" "ADS-B Exchange (adsbexchange.com)" "$FEED_ADSBX" \
        "FEED_OPENSKY" "OpenSky Network (opensky-network.org)  " "$FEED_OPENSKY" \
        "FEED_FLIGHTAWARE" "FlightAware (flightaware.com)" "$FEED_FLIGHTAWARE" \
        "FEED_FLIGHTRADAR24" "Flightradar24 (flightradar24.com)" "$FEED_FLIGHTRADAR24" \
        "FEED_PLANEFINDER" "PlaneFinder (planefinder.net)" "$FEED_PLANEFINDER" \
        "FEED_RADARBOX" "AirNav RadarBox (radarbox.com)" "$FEED_RADARBOX" \
        3>&1 1>&2 2>&3); then
        :
    else
        exit_user_cancelled
    fi

    # Set the variables based on user input
    for feeder in "FEED_ADSBX" "FEED_OPENSKY" "FEED_FLIGHTAWARE" "FEED_FLIGHTRADAR24" "FEED_PLANEFINDER" "FEED_RADARBOX"; do
        if is_X_in_list_Y "\"$feeder\"" "$feeder_prefs"; then
            value="ON"
        else
            value="OFF"
        fi
        case "$feeder" in
            FEED_ADSBX)
                set_env_file_entry FEED_ADSBX $value
                ;;
            FEED_OPENSKY)
                set_env_file_entry FEED_OPENSKY $value
                ;;
            FEED_FLIGHTAWARE)
                set_env_file_entry FEED_FLIGHTAWARE $value
                ;;
            FEED_FLIGHTRADAR24)
                set_env_file_entry FEED_FLIGHTRADAR24 $value
                ;;
            FEED_PLANEFINDER)
                set_env_file_entry FEED_PLANEFINDER $value
                ;;
            FEED_RADARBOX)
                set_env_file_entry FEED_RADARBOX $value
                ;;
        esac
    done

    # re-reads new preferences file so all variables are up to date
    source "$TMPFILE_NEWPREFS"

    # Get ADSBX details
    if  [[ "$FEED_ADSBX" == "ON" ]]; then
        input_adsbx_details
    fi

    # Get FR24 details
    if [[ "$FEED_FLIGHTRADAR24" == "ON" ]]; then
        input_fr24_details
    fi

    # Get flightaware/piaware details
    if [[ "$FEED_FLIGHTAWARE" == "ON" ]]; then
        input_piaware_details
    fi

    # Get planefinder details
    if [[ "$FEED_PLANEFINDER" == "ON" ]]; then
        input_planefinder_details
    fi
    
    # Get Opensky details
    if [[ "$FEED_OPENSKY" == "ON" ]]; then
        input_opensky_details
    fi

    # Get radarbox details
    if [[ "$FEED_RADARBOX" == "ON" ]]; then
        input_radarbox_details
    fi
    
}

function get_visualisation_preferences() {

    # TODO - if previous values exist, "press enter for previous value" or something similar

    source "$TMPFILE_NEWPREFS"

    echo ""
    echo -e "${WHITE}===== Visualisation Preferences =====${NOCOLOR}"
    echo ""

    echo " * ${WHITE}readsb${NOCOLOR} has a web-based map interface displays real-time nearby flights from receiver."
    echo " "

    #if FEED_FLIGHTRADAR24
    
    # TODO Extra cool stuff like:
    #   - ask about visualisations
    #       - readsb/tar1090/vrs/fam/skyaware/etc
    #   - get Bing Maps API key and add to flightaware etc

}

function unload_rtlsdr_kernel_modules() {
    for modulename in "${RTLSDR_MODULES_TO_BLACKLIST[@]}"; do
        if lsmod | grep -i "$modulename" > /dev/null 2>&1; then

            msg="Module '$modulename' must be unloaded to continue. Is this OK?"
            title="Unload of kernel modules required"
            if whiptail --backtitle "$WHIPTAIL_BACKTITLEBACKTITLE" --title "$title" --yesno "$msg" 7 80; then
                if rmmod "$modulename"; then
                    logger "unload_rtlsdr_kernel_modules" "Module '$modulename' unloaded successfully!"
                else
                    logger "unload_rtlsdr_kernel_modules" "ERROR: Could not unload module '$modulename' :-("
                    NEWT_COLORS='root=,red' \
                        whiptail \
                            --title "Error" \
                            --msgbox "Could not unload module '$modulename' :-(" 8 78
                    exit_failure
                fi
            else
                exit_user_cancelled
            fi
        else
            logger "unload_rtlsdr_kernel_modules" "Module '$modulename' is not loaded!"
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

function create_docker_compose_yml_file() {

    source "$PREFSFILE"

    # adjust depends_on depending on feeder...
    case "$DATASOURCE_TYPE" in
        rtlsdr)
            depends_on_readsb=1
            ;;
        *)
            depends_on_readsb=0
            ;;
    esac

    # do we need to create the volumes section?
    if [[ "$FEED_RADARBOX" == "ON" ]]; then
        create_volumes_section=1
    else
        create_volumes_section=0
    fi


    # Top part of compose file
    {
        # write header into docker-compose
        echo "# Please do not remove/modify the two lines below:"
        echo "# ADSB_DOCKER_INSTALL_ENVFILE_SCHEMA=$CURRENT_SCHEMA_VERSION"
        echo "# ADSB_DOCKER_INSTALL_TIMESTAMP=$(date -Iseconds)"
        echo "# -----------------------------------------------"
        echo ""

        # File header
        echo "version: '2.0'"
        echo ""

    } > "$COMPOSEFILE"

    # Define volumes
    if [[ "$create_volumes_section" -eq 1 ]]; then
        {
            echo "volumes:"
            echo ""
        } >> "$COMPOSEFILE"

        # implement fix for segfault - see: https://github.com/mikenye/docker-radarbox/issues/16#issuecomment-699627387
        if [[ "$FEED_RADARBOX" == "ON" ]]; then
            {
                echo "  radarbox_segfault_fix:"
                echo "    driver: local"
                echo "    driver_opts:"
                echo "      type: none"
                echo "      device: $PROJECTDIR/data/radarbox_segfault_fix"
                echo "      o: bind"
            } >> "$COMPOSEFILE"
            mkdir -p "$PROJECTDIR/data/radarbox_segfault_fix/thermal_zone0"
            echo 24000 > "$PROJECTDIR/data/radarbox_segfault_fix/thermal_zone0/temp"
        fi
    fi

    # Define services
    {
        echo "services:"
        echo ""

    } >> "$COMPOSEFILE"

    # ADSBX Service
    {
        echo "  adsbx:"
        echo "    image: mikenye/adsbexchange:latest"
        echo "    tty: true"
        echo "    container_name: adsbx"
        echo "    hostname: adsbx"
        echo "    restart: always"
        echo "    logging:"
        echo "      driver: json-file"
        echo "      options:"
        echo "        max-size: 10m"
        echo "        max-file: 3"
        if [[ "$depends_on_readsb" -eq 1 ]]; then
            echo "    depends_on:"
            echo "      - readsb"
        fi
        echo "    environment:"
        echo '      - ALT=${FEEDER_ALT_M}m'
        echo '      - BEASTHOST=${BEASTHOST}'
        echo '      - BEASTPORT=${BEASTPORT}'
        echo '      - LAT=${FEEDER_LAT}'
        echo '      - LONG=${FEEDER_LONG}'
        echo '      - SITENAME=${ADSBX_SITENAME}'
        echo '      - TZ=${FEEDER_TZ}'
        echo '      - UUID=${ADSBX_UUID}'
        echo ""
    } > "$TMPFILE_DOCKER_COMPOSE_SCRATCH"
    # If this service isn't enabled, comment it out
    if [[ "$FEED_ADSBX" != "ON" ]]; then
        sed -e -i 's/^/# /g' "$TMPFILE_DOCKER_COMPOSE_SCRATCH"
    fi
    cat "$TMPFILE_DOCKER_COMPOSE_SCRATCH" >> "$COMPOSEFILE"

    # FlightAware (piaware) Service
    {
        # TODO - port mapping for skyaware if wanted
        # TODO - bing maps API key
        echo "  piaware:"
        echo "    image: mikenye/piaware:latest"
        echo "    tty: true"
        echo "    container_name: piaware"
        echo "    hostname: piaware"
        echo "    restart: always"
        echo "    logging:"
        echo "      driver: json-file"
        echo "      options:"
        echo "        max-size: 10m"
        echo "        max-file: 3"
        if [[ "$depends_on_readsb" -eq 1 ]]; then
            echo "    depends_on:"
            echo "      - readsb"
        fi
        echo "    environment:"
        echo '      - BEASTHOST=${BEASTHOST}'
        echo '      - BEASTPORT=${BEASTPORT}'
        echo '      - FEEDER_ID=${PIAWARE_FEEDER_ID}'
        echo '      - LAT=${FEEDER_LAT}'
        echo '      - LONG=${FEEDER_LONG}'
        echo '      - TZ=${FEEDER_TZ}'
        echo ""
    } > "$TMPFILE_DOCKER_COMPOSE_SCRATCH"
    # If this service isn't enabled, comment it out
    if [[ "$FEED_FLIGHTAWARE" != "ON" ]]; then
        sed -e -i 's/^/# /g' "$TMPFILE_DOCKER_COMPOSE_SCRATCH"
    fi
    cat "$TMPFILE_DOCKER_COMPOSE_SCRATCH" >> "$COMPOSEFILE"

    # FlightRadar24 Service
    {
        # TODO - port mapping if wanted
        echo "  fr24:"
        echo "    image: mikenye/fr24feed:latest"
        echo "    tty: true"
        echo "    container_name: fr24"
        echo "    hostname: fr24"
        echo "    restart: always"
        echo "    logging:"
        echo "      driver: json-file"
        echo "      options:"
        echo "        max-size: 10m"
        echo "        max-file: 3"
        if [[ "$depends_on_readsb" -eq 1 ]]; then
            echo "    depends_on:"
            echo "      - readsb"
        fi
        echo "    environment:"
        echo '      - BEASTHOST=${BEASTHOST}'
        echo '      - BEASTPORT=${BEASTPORT}'
        echo '      - FR24KEY=${FR24_KEY}'
        echo "      - MLAT=yes"
        echo '      - TZ=${FEEDER_TZ}'
        echo ""
    } > "$TMPFILE_DOCKER_COMPOSE_SCRATCH"
    # If this service isn't enabled, comment it out
    if [[ "$FEED_FLIGHTRADAR24" != "ON" ]]; then
        sed -e -i 's/^/# /g' "$TMPFILE_DOCKER_COMPOSE_SCRATCH"
    fi
    cat "$TMPFILE_DOCKER_COMPOSE_SCRATCH" >> "$COMPOSEFILE"

    # Opensky Service
    {
        echo "  opensky:"
        echo "    image: mikenye/opensky-network:latest"
        echo "    tty: true"
        echo "    container_name: opensky"
        echo "    hostname: opensky"
        echo "    restart: always"
        echo "    logging:"
        echo "      driver: json-file"
        echo "      options:"
        echo "        max-size: 10m"
        echo "        max-file: 3"
        if [[ "$depends_on_readsb" -eq 1 ]]; then
            echo "    depends_on:"
            echo "      - readsb"
        fi
        echo "    environment:"
        echo '      - ALT=${FEEDER_ALT_M}'
        echo '      - BEASTHOST=${BEASTHOST}'
        echo '      - BEASTPORT=${BEASTPORT}'
        echo '      - LAT=${FEEDER_LAT}'
        echo '      - LONG=${FEEDER_LONG}'
        echo '      - OPENSKY_SERIAL=${OPENSKY_SERIAL}'
        echo '      - OPENSKY_USERNAME=${OPENSKY_USERNAME}'
        echo '      - TZ=${FEEDER_TZ}'
        echo ""
    } > "$TMPFILE_DOCKER_COMPOSE_SCRATCH"
    # If this service isn't enabled, comment it out
    if [[ "$FEED_OPENSKY" != "ON" ]]; then
        sed -e -i 's/^/# /g' "$TMPFILE_DOCKER_COMPOSE_SCRATCH"
    fi
    cat "$TMPFILE_DOCKER_COMPOSE_SCRATCH" >> "$COMPOSEFILE"

    # Planefinder Service
    {
        # TODO - port mapping if wanted
        echo "  planefinder:"
        echo "    image: mikenye/planefinder:latest"
        echo "    tty: true"
        echo "    container_name: planefinder"
        echo "    hostname: planefinder"
        echo "    restart: always"
        echo "    logging:"
        echo "      driver: json-file"
        echo "      options:"
        echo "        max-size: 10m"
        echo "        max-file: 3"
        if [[ "$depends_on_readsb" -eq 1 ]]; then
            echo "    depends_on:"
            echo "      - readsb"
        fi
        echo "    environment:"
        echo '      - BEASTHOST=${BEASTHOST}'
        echo '      - BEASTPORT=${BEASTPORT}'
        echo '      - LAT=${FEEDER_LAT}'
        echo '      - LONG=${FEEDER_LONG}'
        echo '      - SHARECODE=${PLANEFINDER_SHARECODE}'
        echo '      - TZ=${FEEDER_TZ}'
        echo ""
    } > "$TMPFILE_DOCKER_COMPOSE_SCRATCH"
    # If this service isn't enabled, comment it out
    if [[ "$FEED_PLANEFINDER" != "ON" ]]; then
        sed -e -i 's/^/# /g' "$TMPFILE_DOCKER_COMPOSE_SCRATCH"
    fi
    cat "$TMPFILE_DOCKER_COMPOSE_SCRATCH" >> "$COMPOSEFILE"

    # Radarbox Service
    {
        # TODO - port mapping if wanted
        echo "  radarbox:"
        echo "    image: mikenye/radarbox:latest"
        echo "    tty: true"
        echo "    container_name: radarbox"
        echo "    hostname: radarbox"
        echo "    restart: always"
        echo "    logging:"
        echo "      driver: json-file"
        echo "      options:"
        echo "        max-size: 10m"
        echo "        max-file: 3"
        if [[ "$depends_on_readsb" -eq 1 ]]; then
            echo "    depends_on:"
            echo "      - readsb"
        fi
        # implement fix for segfault - see: https://github.com/mikenye/docker-radarbox/issues/16#issuecomment-699627387
        echo "    volumes:"
        echo "      - radarbox_segfault_fix:/sys/class/thermal:ro"
        echo "    environment:"
        echo '      - ALT=${FEEDER_ALT_M}'
        echo '      - BEASTHOST=${BEASTHOST}'
        echo '      - BEASTPORT=${BEASTPORT}'
        echo '      - LAT=${FEEDER_LAT}'
        echo '      - LONG=${FEEDER_LONG}'
        echo '      - SHARING_KEY=${RADARBOX_SHARING_KEY}'
        echo '      - TZ=${FEEDER_TZ}'
        echo ""
    } > "$TMPFILE_DOCKER_COMPOSE_SCRATCH"
    # If this service isn't enabled, comment it out
    if [[ "$FEED_RADARBOX" != "ON" ]]; then
        sed -e -i 's/^/# /g' "$TMPFILE_DOCKER_COMPOSE_SCRATCH"
    fi
    cat "$TMPFILE_DOCKER_COMPOSE_SCRATCH" >> "$COMPOSEFILE"

}

function get_datasource_preferences() {

    # TODO:
    #  - # "net_radarcape" "A remote radarcape system."
    #  - # "rtlsdr" "Local RTL-SDR attached to this system."

    source "$TMPFILE_NEWPREFS"

    valid_datasource=0
    while [[ "$valid_datasource" -eq 0 ]]; do

        # determine defaults for radiolist

        default_radiolist_net_sbs="OFF"
        default_radiolist_net_beast="OFF"

        case "$DATASOURCE_TYPE" in
            net_sbs)
                default_radiolist_net_sbs="ON"
                ;;
            net_beast)
                default_radiolist_net_beast="ON"
                ;;
        esac

        # Ask the user what feeder to use
        if DATASOURCE_TYPE=$(whiptail \
            --backtitle "$WHIPTAIL_BACKTITLE" \
            --title "ADS-B ES data source" \
            --radiolist "Select a source for you ADS-B ES 1090MHz data:" \
            20 78 4 \
            "net_sbs" "Remote host providing SBS protocol data." "$default_radiolist_net_sbs" \
            "net_beast" "Remote host providing BEAST protocol data.  " "$default_radiolist_net_beast" \
            3>&1 1>&2 2>&3); then    
            :
        else
            exit_user_cancelled
        fi

        set_env_file_entry DATASOURCE_TYPE "$DATASOURCE_TYPE"

        case "$DATASOURCE_TYPE" in
            net_sbs)

                title="SBS protocol data source"

                valid_input=0
                while [[ "$valid_input" -eq 0 ]]; do
                
                    # Prompt for SBSHOST & SBSPORT
                    if SBSHOST=$(whiptail \
                        --backtitle "$WHIPTAIL_BACKTITLE" \
                        --title "$title"  \
                        --inputbox "Enter the IP address or hostname of an SBS protocol data source:" \
                        8 78 \
                        "$SBSHOST" \
                        3>&1 1>&2 2>&3); then
                        :
                    else
                        exit_user_cancelled
                    fi

                    if SBSPORT=$(whiptail \
                        --backtitle "$WHIPTAIL_BACKTITLE" \
                        --title "$title" \
                        --inputbox "Enter the TCP port of the SBS protocol data source:" \
                        8 78 \
                        "$SBSPORT" \
                        3>&1 1>&2 2>&3); then
                        :
                    else
                        exit_user_cancelled
                    fi

                    msg="Are these settings correct?\n"
                    msg+=" - SBSHOST=$SBSHOST\n"
                    msg+=" - SBSPORT=$SBSPORT"
                    if whiptail \
                        --backtitle "$WHIPTAIL_BACKTITLE" \
                        --title "$title" \
                        --yesno "$msg" \
                        12 78; then
                        :
                        valid_input=1
                    fi
                done

                set_env_file_entry SBSHOST "$SBSHOST"
                set_env_file_entry SBSPORT "$SBSPORT"
                del_env_file_entry BEASTHOST
                del_env_file_entry BEASTPORT
                ;;

            net_beast)

                title="BEAST protocol data source"
            
                valid_input=0
                while [[ "$valid_input" -eq 0 ]]; do
                
                    # Prompt for SBSHOST & SBSPORT
                    if BEASTHOST=$(whiptail \
                        --backtitle "$WHIPTAIL_BACKTITLE" \
                        --title "$title" \
                        --inputbox "Enter the IP address or hostname of a BEAST protocol data source:" \
                        8 78 \
                        "$BEASTHOST" \
                        3>&1 1>&2 2>&3); then
                        :
                    else
                        exit_user_cancelled
                    fi

                    if BEASTPORT=$(whiptail \
                        --backtitle "$WHIPTAIL_BACKTITLE" \
                        --title "$title" \
                        --inputbox "Enter the TCP port of the BEAST protocol data source:" \
                        8 78 \
                        "$BEASTPORT" \
                        3>&1 1>&2 2>&3); then
                        :
                    else
                        exit_user_cancelled
                    fi

                    msg="Are these settings correct?\n"
                    msg+=" - BEASTHOST=$BEASTHOST\n"
                    msg+=" - BEASTPORT=$BEASTPORT"
                    if whiptail \
                        --backtitle "$WHIPTAIL_BACKTITLE" \
                        --title "$title" \
                        --yesno "$msg" \
                        12 78; then
                        :
                        valid_input=1
                    fi
                done

                set_env_file_entry BEASTHOST "$BEASTHOST"
                set_env_file_entry BEASTPORT "$BEASTPORT"
                del_env_file_entry SBSHOST
                del_env_file_entry SBSPORT
                ;;
        esac

        # sanity checks
        valid_datasource=1
        case "$DATASOURCE_TYPE" in
            net_sbs)
                if [[ -z "$SBSHOST" ]]; then
                    valid_datasource=0
                    whiptail \
                        --clear \
                        --backtitle "$WHIPTAIL_BACKTITLE" \
                        --title "Invalid SBS host!" \
                        --msgbox "Please enter a valid SBS host.\nCannot be blank." \
                        10 74
                elif [[ "$SBSHOST" == "localhost" ]]; then
                    valid_datasource=0
                    whiptail \
                        --clear \
                        --backtitle "$WHIPTAIL_BACKTITLE" \
                        --title "Invalid SBS host!" \
                        --msgbox "Please enter a valid SBS host.\nYou cannot use 'localhost', instead use the LAN IP address of this host." \
                        10 74
                elif [[ "$SBSHOST" == "127.0.0.1" ]]; then
                    valid_datasource=0
                    whiptail \
                        --clear \
                        --backtitle "$WHIPTAIL_BACKTITLE" \
                        --title "Invalid SBS host!" \
                        --msgbox "Please enter a valid SBS host.\nYou cannot use 'localhost', instead use the LAN IP address of this host." \
                        10 74
                elif ! ((SBSPORT >= 1024 && SBSPORT <= 65535)); then
                    valid_datasource=0
                    whiptail \
                        --clear \
                        --backtitle "$WHIPTAIL_BACKTITLE" \
                        --title "Invalid SBS port!" \
                        --msgbox "Please enter a valid SBS TCP port.\nThe port must be between 1024-65535 (inclusive) and is typically 30003." \
                        10 74
                fi
                ;;
            net_beast)
                if [[ -z "$BEASTHOST" ]]; then
                    valid_datasource=0
                    whiptail \
                        --clear \
                        --backtitle "$WHIPTAIL_BACKTITLE" \
                        --title "Invalid BEAST host!" \
                        --msgbox "Please enter a valid SBS host.\nCannot be blank." \
                        10 74
                elif [[ "$BEASTHOST" == "localhost" ]]; then
                    valid_datasource=0
                    whiptail \
                        --clear \
                        --backtitle "$WHIPTAIL_BACKTITLE" \
                        --title "Invalid BEAST host!" \
                        --msgbox "Please enter a valid BEAST host.\nYou cannot use 'localhost', instead use the LAN IP address of this host." \
                        10 74
                elif [[ "$BEASTHOST" == "127.0.0.1" ]]; then
                    valid_datasource=0
                    whiptail \
                        --clear \
                        --backtitle "$WHIPTAIL_BACKTITLE" \
                        --title "Invalid BEAST host!" \
                        --msgbox "Please enter a valid BEAST host.\nYou cannot use 'localhost', instead use the LAN IP address of this host." \
                        10 74
                elif ! ((BEASTPORT >= 1024 && BEASTPORT <= 65535)); then
                    valid_datasource=0
                    whiptail \
                        --clear \
                        --backtitle "$WHIPTAIL_BACKTITLE" \
                        --title "Invalid BEAST port!" \
                        --msgbox "Please enter a valid BEAST TCP port.\nThe port must be between 1024-65535 (inclusive) and is typically 30005." \
                        10 74
                fi
                ;;
        esac
    done
}

function show_post_deploy_help() {

    echo -e "\n\n"
    echo -e "${LIGHTGREEN}Congratulations on your new Docker-based ADS-B deployment!${NOCOLOR}"
    echo ""
    echo -e "${LIGHTBLUE}Deployment Info:${NOCOLOR}"
    echo -e " - The ${WHITE}project directory${NOCOLOR} is '${WHITE}$PROJECTDIR${NOCOLOR}'. You should cd into this directory before running any 'docker-compose' commands for your ADS-B containers."
    echo -e " - The ${WHITE}compose file${NOCOLOR} is '${WHITE}$PROJECTDIR/docker-compose.yml${NOCOLOR}'."
    echo -e " - The ${WHITE}environment file${NOCOLOR} is '${WHITE}$PROJECTDIR/.env${NOCOLOR}'."
    echo -e " - The ${WHITE}container data${NOCOLOR} is stored under '${WHITE}$PROJECTDIR/data/${NOCOLOR}'."
    echo ""
    echo -e "${LIGHTBLUE}Basic Help:${NOCOLOR}"
    echo -e " - To bring the environment up: ${WHITE}cd $PROJECTDIR; docker-compose up -d${NOCOLOR}"
    echo -e " - To bring the environment down: ${WHITE}cd $PROJECTDIR; docker-compose down${NOCOLOR}"
    echo -e " - To view the environment logs: ${WHITE}cd $PROJECTDIR; docker-compose logs -f${NOCOLOR}"
    echo -e " - To view the logs for an individual container: ${WHITE}docker logs -f <container>${NOCOLOR}"
    echo -e " - To view running containers: ${WHITE}docker ps${NOCOLOR}"
    echo ""
    echo -e "${LIGHTBLUE}Next steps for you (yes you reading this!):${NOCOLOR}"
    echo " - Wait for 5-10 minutes for some data to be sent..."
    if [[ "$FEED_ADSBX" == "ON" ]]; then
        echo -e " - Go to ${WHITE}https://adsbexchange.com/myip/${NOCOLOR} to check the status of your feeder."
    fi
    if [[ "$FEED_FLIGHTAWARE" == "ON" ]]; then
        echo -e " - If you haven't already, go to ${WHITE}https://flightaware.com/adsb/piaware/claim${NOCOLOR} and claim your receiver."
    fi
    if [[ "$FEED_FLIGHTRADAR24" == "ON" ]]; then
        echo -e " - If you haven't already, go to ${WHITE}https://www.flightradar24.com${NOCOLOR} and create your account."
    fi
    if [[ "$FEED_RADARBOX" == "ON" ]]; then
        echo -e " - If you haven't already, go to ${WHITE}https://www.radarbox.com/raspberry-pi/claim${NOCOLOR} and claim your receiver."
    fi
    if [[ "$FEED_PLANEFINDER" == "ON" ]]; then
        echo -e " - If you haven't already, go to ${WHITE}https://www.planefinder.net/${NOCOLOR} 'Account' > 'Manage Receivers' and press 'Add receiver' to claim your receiver."
    fi
    echo ""
    echo "If you need to reconfigure the environment, just run this script again."
    echo "Thanks!"
    echo -e "\n"
}

##### MAIN SCRIPT #####

# Initialise log file
rm "$LOGFILE" > /dev/null 2>&1 || true
logger "main" "Script started"
#shellcheck disable=SC2128,SC1102
command_line="$(printf %q "$BASH_SOURCE")$((($#)) && printf ' %q' "$@")"
logger "main" "Full command line: $command_line"

# Make sure the script is being run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root! Try 'sudo $command_line'" 
   exit 1
fi

# Display welcome message
welcome_msg

# Configure project directory
msg="Please enter a path for the ADS-B docker project.\n"
msg+="This is where the docker-compose.yml and .env file will be stored,\n"
msg+="as well as all application data."
title="Project Path"
if PROJECTDIR=$(whiptail --backtitle "$WHIPTAIL_BACKTITLE" --inputbox "$msg" --title "$title" 9 78 "/opt/adsb" 3>&1 1>&2 2>&3); then
    if [[ -d "$PROJECTDIR" ]]; then
        logger "main" "Project directory $PROJECTDIR already exists!"
    else
        logger "main" "Creating project directory $PROJECTDIR..."
        mkdir -p "$PROJECTDIR" || exit 1
    fi
else
    exit_user_cancelled
fi

# Update & export variables based on $PROJECTDIR
PREFSFILE="$PROJECTDIR/.env"
COMPOSEFILE="$PROJECTDIR/docker-compose.yml"
TMPFILE_NEWPREFS="$PROJECTDIR/.env.new_from_adsb_docker_install"
export PROJECTDIR PREFSFILE COMPOSEFILE TMPFILE_NEWPREFS

# Check if "$PREFSFILE" exists
if [[ -e "$PREFSFILE" ]]; then
    logger "main" "Environment variables file $PREFSFILE already exists."
    source "$PREFSFILE"
    if [[ "$ADSB_DOCKER_INSTALL_ENVFILE_SCHEMA" -ne "$CURRENT_SCHEMA_VERSION" ]]; then
        logger "main" "Environment variable file $PREFSFILE was not created by this script!"
        if whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Environment variable file already exists!" --yesno "Existing environment variables file $PREFSFILE was not created by this script! Do you want this script to take a backup of this file and continue?" 10 78; then
            BACKUPFILE="$PREFSFILE.backup.$(date -Iseconds)"
            cp -v "$PREFSFILE" "$BACKUPFILE" >> "$LOGFILE" 2>&1 || exit 1
            logger "main" "Backup of $PREFSFILE to $BACKUPFILE completed!"
        else
            exit_user_cancelled
        fi
    fi
fi

# Check if "$TMPFILE_NEWPREFS" exists
if [[ -e "$TMPFILE_NEWPREFS" ]]; then
    logger "main" "" "$LIGHTBLUE"
    if whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Import Settings From Previous Run?" --yesno "It looks like a previous run of this script did not complete successfully. Do you want this script to import settings from the previous run?" 10 78; then
        logger "main" "Reading in settings from $TMPFILE_NEWPREFS"
        source "$TMPFILE_NEWPREFS" || exit 1
    else
        logger "main" "Initialising $TMPFILE_NEWPREFS"
        # Set up "$TMPFILE_NEWPREFS"
        {
            echo "# Please do not remove/modify the two lines below:"
            echo "ADSB_DOCKER_INSTALL_ENVFILE_SCHEMA=$CURRENT_SCHEMA_VERSION"
            echo "ADSB_DOCKER_INSTALL_TIMESTAMP=$(date -Iseconds)"
            echo "# -----------------------------------------------"
        } > "$TMPFILE_NEWPREFS"
    fi
else
    logger "main" "Initialising $TMPFILE_NEWPREFS"
    # Set up "$TMPFILE_NEWPREFS"
    {
        echo "# Please do not remove/modify the two lines below:"
        echo "ADSB_DOCKER_INSTALL_ENVFILE_SCHEMA=$CURRENT_SCHEMA_VERSION"
        echo "ADSB_DOCKER_INSTALL_TIMESTAMP=$(date -Iseconds)"
        echo "# -----------------------------------------------"
    } > "$TMPFILE_NEWPREFS"
fi

# Check if "$COMPOSEFILE" exists
if [[ -e "$COMPOSEFILE" ]]; then
    logger "main" "Compose file $COMPOSEFILE already exists."
    source "$PREFSFILE"
    if ! grep -oP "$REGEX_PATTERN_COMPOSEFILE_SCHEMA_HEADER" "$COMPOSEFILE"; then
        logger "main" "Existing compose file $COMPOSEFILE was not created by this script!"
        echo ""
        if whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Existing compose file found" --yesno "Existing compose file $COMPOSEFILE was not created by this script! Do you want this script to backup the file and continue?" 10 78; then
            BACKUPFILE="$COMPOSEFILE.backup.$(date -Iseconds)"
            cp -v "$COMPOSEFILE" "$BACKUPFILE" || exit 1
            logger "main" "Backup of $COMPOSEFILE to $BACKUPFILE completed!"
        else
            exit_user_cancelled
        fi
    fi
fi

# Ensure apt-get update has been run
update_apt_repos

# Install required packages / prerequisites (curl, docker, temp container, docker-compose)
# Get curl
if ! is_binary_installed curl; then
    msg="This script needs to install the 'curl' utility, which is used for:\n"
    msg+=" * Automatic submission of Planefinder sign-up form\n"
    msg+="Is it ok to install curl?"
    if whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Package installation" --yesno "$msg" 12 80; then
        install_with_apt curl
    else
        exit_user_cancelled
    fi
fi
# Get expect
if ! is_binary_installed expect; then
    msg="This script needs to install the 'expect' utility, which is used for:\n"
    msg+=" * Automatic completion of feeder sign-up tasks\n"
    msg+="Is it ok to install expect?"
    if whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Package installation" --yesno "$msg" 12 80; then
        install_with_apt expect
    else
        exit_user_cancelled
    fi
fi
# Deploy docker
if ! is_binary_installed docker; then
    msg="This script needs to install docker, which is used for:\n"
    msg+=" * Running the containers!\n"
    msg+="Is it ok to install docker?"
    if whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Package docker" --yesno "$msg" 12 80; then
        install_docker
    else
        exit_user_cancelled
    fi
else
    update_docker
fi
# Deploy docker compose
get_latest_docker_compose_version
if ! is_binary_installed docker-compose; then
    msg="This script needs to install docker-compose, which is used for:\n"
    msg+=" * Management and orchestration of containers!\n"
    msg+="Is it ok to install docker-compose?"
    if whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "docker-compose" --yesno "$msg" 12 80; then
        install_docker_compose
    else
        exit_user_cancelled
    fi
else
    update_docker_compose
fi
# Deploy temp container (for working & utilities required by this script)
logger "main" "Deploying temporary helper container to assist with install..."
whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "Deploying temporary helper container to assist with install..." 8 78
# the sleep ensures the container will remove itself after an hour
if CONTAINER_ID_TEMPORARY=$(docker run -d --rm -v "$PROJECTDIR":"$PROJECTDIR" "$IMAGE_TEMPORARY_HELPER" sleep 3600); then
    logger "main" "Temp container $CONTAINER_ID_TEMPORARY deployed OK"
else
    logger "main" "Failed to deploy temporary helper container :-("
    NEWT_COLORS='root=,red' \
        whiptail \
            --title "Error" \
            --msgbox "Failed to deploy temporary helper container :-(" 8 78
    exit_failure
fi
export CONTAINER_ID_TEMPORARY
logger "main" "Temporary helper container deployed and running!"

# Unload and blacklist rtlsdr kernel modules
unload_rtlsdr_kernel_modules

# Get/Set preferences
confirm_prefs=0
while [[ "$confirm_prefs" -eq "0" ]]; do

        # Get preferences from user
        #get_rtlsdr_preferences # TODO - finish this section
        input_timezone
        input_lat_long
        input_altitude
        get_datasource_preferences
        get_feeder_preferences
        # TODO - visualisation preferences
        # TODO - provide data externally details 

        title="Confirm Settings"
        msg="Please confirm all settings (scroll with arrow keys):\n\n"
        msg+=$(grep -vP "$REGEX_PATTERN_COMMENTS" "$TMPFILE_NEWPREFS" | grep -vP '^ADSB_DOCKER_INSTALL_')
        msg+="\n--end of settings--"
        if (whiptail \
                --backtitle="$WHIPTAIL_BACKTITLE" \
                --title "$title" \
                --yes-button "Correct" \
                --no-button "Re-enter" \
                --yesno "$msg" \
                18 78 \
                --scrolltext); then
            confirm_prefs=1
        fi
done

# Save settings?
title="Commit settings?"
msg="Do you want to save settings and create/recreate ADS-B containers?"
if (whiptail \
        --backtitle="$WHIPTAIL_BACKTITLE" \
        --title "$title" \
        --yes-button "Proceed" \
        --no-button "Abort" \
        --yesno "$msg" \
        8 78 ); then
    :
else
    exit_user_cancelled
fi

# Create .env file
cp -v "$TMPFILE_NEWPREFS" "$PREFSFILE" >> "$LOGFILE" 2>&1

# Create docker-compose.yml file
create_docker_compose_yml_file

# start containers
pushd "$PROJECTDIR" >> "$LOGFILE" 2>&1 || exit_user_cancelled
whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "Pulling (downloading) images..." 8 78
if docker-compose pull >> "$LOGFILE" 2>&1; then
    :
else
    docker-compose down >> "$LOGFILE" 2>&1 || true
    NEWT_COLORS='root=,red' \
        whiptail \
            --title "Error" \
            --msgbox "Failed to pull (download) images :-(" 8 78
    exit_failure
fi
whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "Working..." --infobox "Starting containers..." 8 78
if docker-compose up -d --remove-orphans >> "$LOGFILE" 2>&1; then
    whiptail \
        --clear \
        --backtitle "$WHIPTAIL_BACKTITLE" \
        --msgbox "Containers have been started!" \
        --title "Containers started!" \
        8 40
else
    docker-compose down >> "$LOGFILE" 2>&1 || true
    NEWT_COLORS='root=,red' \
        whiptail \
            --title "Error" \
            --msgbox "Failed to start containers :-(" 8 78
    exit_failure
fi
popd  >> "$LOGFILE" 2>&1 || exit_user_cancelled

# If we're here, then everything should've gone ok, so we can delete the temp prefs file
rm "$TMPFILE_NEWPREFS"

# print some help
show_post_deploy_help

# FINISHED!
