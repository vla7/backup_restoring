#!/bin/bash
if [ -z "$3" ]
then
        echo "Not enough parameters: $0 old_id new_id vz_serv [external]";
        exit 0
fi
sshopts="-q -o StrictHostKeyChecking=no -o CheckHostIP=no -o UserKnownHostsFile=/dev/null"
#sshopts="-o LogLevel=QUIET"
n=`echo "$1" | sed 's#^p##g'`
new_n=`echo "$2" | sed 's#^p##g'`
vz=$3
host="${vz}.site.net"

#local or external network
if [ "$4" = "external" ];
then
    ip=$host
else
        #find local ip
        ip=`ssh $sshopts root@$host -tt "ip -4 addr | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127.' | grep '^10\.' | head -1" | tr -d '\r'`
        if [ -z "$ip"  ]; then
                echo "Ip not found"; 
                exit
        else
                echo "Ip found: $ip"
        fi
fi

#find backup path
path=`ls -d /backup/VZs/$n 2>/dev/null`
if [ ! -d "$path" ]; then
        path=`ls -d /backup/VZs/to_delete/*/$n 2>/dev/null`
fi

if [ ! -d "$path" ]; then
        echo "Bak path not found"
        exit
else
        echo "Bak path found: $path"
fi
echo;

#find destination path
dest=`ssh $sshopts root@$ip -tt "ls -d /vz*/private/$new_n/root.hdd/root.hd[ds] 2>/dev/null" | tr -d '\r'`
dest_dir=`echo $dest | sed 's#/root\.hdd/root\.hd[sd]$#/root.hdd#g'`

if [ -z "$dest"  ]; then
        echo "No destination found"
        exit
else
        echo "Destination: $dest"
        echo
fi

#determinate hdd path
root_hd=`ls -1 ${path}/root.hd[ds] 2>/dev/null`
if [ -z "$root_hd" ]; then
        echo "root.hd[ds] not found"
        exit
fi

#check compatibility
bk_drive=`basename "$root_hd"`
vz_drive=`basename "$dest"`
if [ $bk_drive == 'root.hds' ] && [ $vz_drive == 'root.hdd' ]; then
        echo "Unable to restore Virtuozzo root.hds to OpenVZ6."
        exit
fi

#determinate last delta and patch if found
last_delta=`ls -1 ${root_hd}.delta_* 2>/dev/null | sort -rn | head -1`
if [ -f "$last_delta" ];
then
        echo "Delta found. Select which one to restore..."
        select delta in `ls -1 $root_hd* | grep -P 'root.hd[ds]$|root.hd[ds].delta_\d{4}_\d{2}_\d{2}$'`
        do
        if [ -z "$delta" ]; then
                echo
                echo "Failed select"
                exit
        elif `echo "$delta" | grep -q 'root.hd[ds]$'`; then
                echo
                echo "Selected original hdd"
                last_delta=""
                break
        fi
                echo
                echo "Patching selected delta..."
                rdiff --hash=md4 patch $root_hd $delta ${root_hd}_restored
        break
        done
        echo
fi

#Check if snapshot like root.hds.{d7c269d6-efa4-4756-9fb3-0b8f005e3d9b} merge needed 
echo "Check if snapshot merge needed..."
snap=`ssh $sshopts root@$ip -tt "ls -1 ${dest}.\{*\} 2>/dev/null" | tr -d '\r'`
if [ -n "$snap"  ]; then
        echo "Snapshot on destination found, merging..."
        echo $snap
        ssh $sshopts root@$ip -tt "prl_disk_tool merge --hdd $dest_dir"
        echo;
fi


#copy hdd
if [ -f "$last_delta" ];
then
        echo "Copying patched hdd..."
        scp -v $sshopts ${root_hd}_restored $ip:${dest}_from_backup && rm -f ${root_hd}_restored

        #stop VPS
        #echo "Vz destination found. Stopping serv and movind hd[ds]"
        now=$(date +"%Y-%m-%d-%H-%M-%S")
        ssh $sshopts root@$ip -tt "vzctl stop $new_n && mv $dest ${dest}.orig.${now} && mv ${dest}_from_backup ${dest}"
        echo
elif [ -f "$root_hd" ];
then
        echo "Copying hdd..."
        scp $sshopts $root_hd $ip:${dest}_from_backup

        #stop VPS
        #echo "Vz destination found. Stopping serv and movind hd[ds]"
        now=$(date +"%Y-%m-%d-%H-%M-%S")
        ssh $sshopts root@$ip -tt "vzctl stop $new_n && mv $dest ${dest}.orig.${now} && mv ${dest}_from_backup ${dest}"
        echo
else
        echo "No hdd found"
fi
echo

#mount for IP replacing
if [ "$n" -ne "$new_n" ]; then #different other VEID of current and previous
echo "IP replacing..."
echo
new_ip=`ssh $sshopts root@$ip -tt "grep IP_ADDRESS /etc/vz/conf/${new_n}.conf | grep -oP '\d+(\.\d+){3}' | grep -vP '^(127\.|10\.|\:)'" | tr -d '\r'`
echo "new_ip=$new_ip"
if [ $? -eq 1 ];then
        echo "Not found new VPS IP in conf: IP replace skipped"
elif [ `echo "$new_ip" | wc -l` -gt 1 ]; then
        echo "More than one new VPS IP in conf found: IP replace skipped $new_ip"
elif [ `echo "$new_ip" | wc -l` -eq 1 ]; then
        echo "Mounting hd..."
        ssh $sshopts root@$ip -tt "vzctl mount $new_n"
        mount_path=`echo $dest_dir | sed 's#private#root#g' | sed 's#/root.hdd$##g'`
        echo "mount_path=$mount_path"
        ssh $sshopts root@$ip -tt "[ -f ${mount_path}/etc/debian_version ]" && os="debian"
        ssh $sshopts root@$ip -tt "[ -f ${mount_path}/etc/centos-release ]" && os="centos"
        if [ -n "$os" ]; then
                echo "OS detected: $os"
                if [ "$os" == "debian" ]; then
                        old_ip=$(ssh $sshopts root@$ip -tt "grep address ${mount_path}/etc/network/interfaces | awk '{print \$2}' | grep -vP '^127\.|^10\.|\:'" | tr -d '\r')
                else
                        old_ip=$(ssh $sshopts root@$ip -tt "grep -r IPADDR ${mount_path}/etc/sysconfig/network-scripts/ifcfg-* | grep -v ifcfg-lo | awk -F= '{print \$2}' | grep -vP '^(127\.|10\.|\:)'" | tr -d '\r')
                fi

                if [ -z "$old_ip" ]; then
                        echo "Old IP not found"
                elif [ `echo "$old_ip" | wc -l` -gt 1 ]; then
                        echo "More than one old IP found: IP replace skipped $old_ip"
                elif [ `echo "$old_ip" | wc -l` -eq 1 ]; then
                        echo "Replacing old_ip $old_ip to new_ip $new_ip"
                        #echo 'ssh $sshopts root@$ip -tt "grep -rl $old_ip ${mount_path}/etc/ | while read f; do sed -i "s/$old_ip/$new_ip/g" "\$f"; done"'
                        ssh $sshopts root@$ip -tt "grep -rl $old_ip ${mount_path}/etc/ | while read f; do sed -i \"s/$old_ip/$new_ip/g\" \"\$f\"; done"
                        ssh $sshopts root@$ip -tt "sed -i \"s/$old_ip/$new_ip/g\" ${mount_path}/usr/local/mgr5/etc/ihttpd.conf"
                        ssh $sshopts root@$ip -tt "sed -i \"s/$old_ip/$new_ip/g\" ${mount_path}/usr/local/ispmgr/etc/nginx.domain"
                fi
        else
                echo "OS not detected: IP replace skipped"
        fi

        echo "Umounting hd..."
        ssh $sshopts root@$ip -tt "vzctl umount $new_n"
        echo
fi
echo
fi
#exit



#start
if [ "$new_n" -eq "10000001" ]; then
        echo "Mounting vz..."
        ssh $sshopts root@$ip -tt "vzctl mount $new_n"
        echo
else
        echo "Starting vz..."
        ssh $sshopts root@$ip -tt "vzctl start $new_n"

        echo
        space=`ssh $sshopts root@$ip -tt "grep -i diskspace /etc/vz/conf/${new_n}.conf | awk -F= '{print \\$2}' | sed -e 's#[\"'\'']##g'" | tr -d '\r'`
        echo "Fixing disk space to current paid sizr. Set space=$space"
        ssh $sshopts root@$ip -tt "vzctl set ${new_n} --diskspace $space --save"

        #reply for ticket
        if [ "$n" -eq "$new_n" ]; then
                echo "Ответ для запроса: Услуга $n восстановлена из бекапа состоянием на _"
        else
                echo "Ответ для запроса: Бекап услуги p$n восстановлен в новый заказ p$new_n"
        fi
        echo "*** Не забудь удалить ${dest}.orig.${now} на $3 ***"
        echo "Команда для удаения:" 
        echo "ssh $sshopts root@$ip -tt \"rm -f ${dest}.orig.${now}\""
fi
