#!/usr/bin/bash

#------------------------------------------------------------------------------#
#                                                                              #
#  Function: Create apache 2.4 instances at any location using                 #
#            base Fedora httpd install, selinux and systemd                    #
#  Author: Edward Quick                                                        #
#  License: GPL                                                                #
#  Usage: ./mksite.sh -a create -n demo -p 8900                                #
#                                                                              #
#------------------------------------------------------------------------------#

# CONFIGURATION

base_dir=/opt/apache
user=apache
group=apache
action=create

# END OF CONFIGURATION #

# FUNCTIONS #

f_usage() { 
  cat <<EOT
Usage: $0 -n <instance name> -p <port>
optional: -a <create|delete> -b <base directory> -u <user> -g <group>

EOT
  exit 1;
}

f_syncheck() {
  test -z $1 && f_usage
}

f_proceed() {
  cat <<EOT

$action apache instance with the following configuration?

  name  = $name
EOT
  [ $action = 'create' ] && cat <<EOT
  port  = $port
  user  = $user
  group = $group
EOT
  cat <<EOT
  server root = $server_root
  service unit = $service_unit

EOT
  echo -ne 'Enter y|n (n): '
  read response
  response=${response,,} # tolower
  if [[ $response =~ ^(yes|y) ]]; then
    echo 'Proceeding'
  else
    echo 'No problem. Aborting.'
    exit
  fi
}

# END OF FUNCTIONS #

# MAIN PROGRAM #

[ $# -eq 0 ] && echo "No options were passed" && f_usage

while getopts "a:b:g:p:n:u:" o; do
  case $o in
    a)
      action=$OPTARG
      [ $action = 'create' ] || [ $action = 'delete' ] || usage
      ;;
    b)
      base_dir=$OPTARG
      f_syncheck $base_dir
      ;;
    g)
      group=$OPTARG
      f_syncheck $group
      ;;
    p)
      port=$OPTARG
      ;;
    n)
      name=$OPTARG
      f_syncheck $name
      ;;
    u)
      user=$OPTARG
      f_syncheck $user
      ;;
    *)
      f_usage
      ;;
  esac
done
shift $((OPTIND-1))

# Mandatory flags
f_syncheck $action
f_syncheck $name
[ $action = 'create' ] && f_syncheck $port

server_root=$base_dir/$name
service_unit=$user@$name.service
f_proceed

# CREATE AN APACHE INSTANCE
if [ $action = 'create' ]; then
  # create group and user
  getent group $group >/dev/null || groupadd $group
  getent passwd $user > /dev/null || useradd -s /sbin/nologin -g $group $user

  # set up the instance directory
  if [ ! -d $server_root ]; then
    mkdir -p $server_root
    cp -a /etc/httpd/{conf,conf.d,conf.modules.d} $server_root
    mkdir $server_root/logs $server_root/run $server_root/bin
    ln -s /usr/lib64/httpd/modules $server_root/modules
    cp -a /usr/sbin/apachectl $server_root/bin/apachectl

    sed -i "s,Listen 80,Listen $port," $server_root/conf/httpd.conf
    sed -i "s,User apache,User $user," $server_root/conf/httpd.conf
    sed -i "s,Group apache,Group $user," $server_root/conf/httpd.conf
    sed -i "/^ServerRoot/s,.*,ServerRoot $server_root," $server_root/conf/httpd.conf
    sed -i "s,$server_root,$server_root\nPidFile run/httpd.pid\nDefaultRuntimeDir run," $server_root/conf/httpd.conf
    sed -i "s,httpd.service,$service_unit," $server_root/bin/apachectl
    chown -hR $user:$user $server_root
  fi

  # set up selinux labels
  if [ ! -f /usr/local/bin/runcon_httpd ]; then
    cp -av /usr/bin/runcon /usr/local/bin/runcon_httpd
    semanage fcontext -a -t httpd_initrc_exec_t /usr/local/bin/runcon_httpd
    restorecon /usr/local/bin/runcon_httpd
  fi

  semanage port -a -t http_port_t -p tcp $port
  semanage fcontext -a -t httpd_var_run_t "$server_root/run"
  restorecon -R -v $server_root/run
  semanage fcontext -a -t httpd_log_t "$server_root/logs"
  restorecon -R -v $server_root/logs
  semanage fcontext -a -t httpd_modules_t "$server_root/modules"
  restorecon -R -v $server_root/modules
  for i in conf conf.d conf.modules.d; do
    semanage fcontext -a -t httpd_config_t "$server_root/$i"
    restorecon -R -v $server_root/$i
  done

  # set up systemd unit and start
  cat <<EOT>/usr/lib/systemd/system/$service_unit
  [Unit]
  Description=Apache Instance - $name

  [Service]
  User=$user
  ExecStart=/usr/local/bin/runcon_httpd -t httpd_t httpd -k start -d $server_root
  PIDFile=$server_root/run/httpd.pid

  [Install]
  WantedBy=multi-user.target
EOT

  systemctl daemon-reload
  systemctl enable $service_unit
  systemctl start $service_unit
  sleep 2
  systemctl status $service_unit

# DELETE AN APACHE INSTANCE
elif [ $action = 'delete' ]; then
  systemctl stop $service_unit
  systemctl disable $service_unit
  rm -f /usr/lib/systemd/system/$service_unit
  systemctl daemon-reload
  rm -rf $server_root

# USAGE
else
  f_usage
fi
